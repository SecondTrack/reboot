#import "RBNet.h"
#import "MeshL10n.h"
#import "mbedtls/ssl.h"
#import "mbedtls/net_sockets.h"
#import "mbedtls/ctr_drbg.h"
#import "mbedtls/x509_crt.h"
#import "mbedtls/error.h"
#import "psa/crypto.h"

static NSURL *RBAbsURL(NSString *s, NSURL *base) { return [(NSURL *)[NSURL URLWithString:s relativeToURL:base] absoluteURL]; }

@implementation RBResponse @end

#define MAX_REDIRECTS 8
#define READ_TIMEOUT_MS 20000

static int rbEntropy(void *d, unsigned char *o, size_t n) { (void)d; arc4random_buf(o, n); return 0; }

// Stammzertifikate einmal aus dem App-Bundle laden (cacert.pem)
static mbedtls_x509_crt *caChain(void) {
    static mbedtls_x509_crt ca; static BOOL ok = NO; static dispatch_once_t once;
    dispatch_once(&once, ^{
        psa_crypto_init();                              // nötig für TLS 1.3 in mbedTLS 3.x
        mbedtls_x509_crt_init(&ca);
        NSString *p = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
        NSMutableData *d = [NSMutableData dataWithContentsOfFile:p];
        if (d) { [d appendBytes:"\0" length:1];          // PEM-Parser braucht abschließendes NUL
                 ok = mbedtls_x509_crt_parse(&ca, d.bytes, d.length) >= 0 && ca.raw.len > 0; }
    });
    return ok ? &ca : NULL;
}

// ---- einfacher Cookie-Speicher (nur für diese Sitzung, pro Host) ----
static NSMutableDictionary *gCookies;
static NSString *cookieHeader(NSString *host) {
    @synchronized ([RBNet class]) {
        NSDictionary *c = gCookies[host.lowercaseString];
        if (!c.count) return nil;
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *k in c) [a addObject:[NSString stringWithFormat:@"%@=%@", k, c[k]]];
        return [a componentsJoinedByString:@"; "];
    }
}
static void storeCookie(NSString *host, NSString *setCookie) {
    NSString *pair = [[setCookie componentsSeparatedByString:@";"] firstObject];
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound) return;
    NSString *k = [[pair substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *v = [pair substringFromIndex:eq.location + 1];
    if (!k.length) return;
    @synchronized ([RBNet class]) {
        if (!gCookies) gCookies = [NSMutableDictionary dictionary];
        NSMutableDictionary *c = gCookies[host.lowercaseString] ?: [NSMutableDictionary dictionary];
        c[k] = v; gCookies[host.lowercaseString] = c;
    }
}

static NSData *dechunk(NSData *d) {
    NSMutableData *out = [NSMutableData data]; const unsigned char *b = d.bytes; NSUInteger n = d.length, p = 0;
    while (p < n) {
        NSUInteger e = p; while (e + 1 < n && !(b[e] == '\r' && b[e+1] == '\n')) e++;
        if (e + 1 >= n) break;
        char tmp[20]; NSUInteger len = MIN(e - p, (NSUInteger)19); memcpy(tmp, b + p, len); tmp[len] = 0;
        long sz = strtol(tmp, NULL, 16);                // Chunk-Erweiterungen hinter ';' ignoriert strtol
        p = e + 2; if (sz <= 0) break;
        if (p + (NSUInteger)sz > n) sz = (long)(n - p);
        [out appendBytes:b + p length:(NSUInteger)sz]; p += (NSUInteger)sz + 2;
    }
    return out;
}

// Eine einzelne Anfrage ohne Weiterleitung. Liefert rohe Antwort (Header+Body) oder Fehler.
static NSData *rawRequest(NSURL *url, NSUInteger maxBytes, NSString **err, void (^progress)(NSUInteger)) {
    BOOL tls = [url.scheme.lowercaseString isEqualToString:@"https"];
    NSString *host = url.host;
    if (!host.length) { *err = L(@"Invalid address"); return nil; }
    NSString *port = url.port ? url.port.stringValue : (tls ? @"443" : @"80");
    NSString *path = url.path.length ? CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)url)) : @"/";
    if (!path.length) path = @"/";
    if (url.query.length) path = [path stringByAppendingFormat:@"?%@", url.query];

    NSMutableString *req = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n", path, host];
    [req appendString:@"User-Agent: Mozilla/5.0 (Linux; Android 4.4; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) RebootAppstore/0.2\r\n"];
    [req appendString:@"Accept: text/html,application/xhtml+xml,text/plain;q=0.9,image/*;q=0.8,*/*;q=0.5\r\n"];
    [req appendString:@"Accept-Language: de-DE,de;q=0.9,en;q=0.7\r\nAccept-Encoding: identity\r\nConnection: close\r\n"];
    NSString *ck = cookieHeader(host); if (ck) [req appendFormat:@"Cookie: %@\r\n", ck];
    [req appendString:@"\r\n"];
    NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];

    mbedtls_net_context net; mbedtls_ssl_context ssl; mbedtls_ssl_config conf; mbedtls_ctr_drbg_context drbg;
    mbedtls_net_init(&net); mbedtls_ssl_init(&ssl); mbedtls_ssl_config_init(&conf); mbedtls_ctr_drbg_init(&drbg);
    NSMutableData *resp = nil; int rc;

    if ((rc = mbedtls_net_connect(&net, host.UTF8String, port.UTF8String, MBEDTLS_NET_PROTO_TCP)) != 0) {
        *err = L(@"Server not reachable"); goto done;
    }
    if (tls) {
        mbedtls_x509_crt *ca = caChain();
        if (!ca) { *err = L(@"Certificate list missing"); goto done; }
        if (mbedtls_ctr_drbg_seed(&drbg, rbEntropy, NULL, (const unsigned char *)"rebootst", 6) != 0 ||
            mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
            *err = L(@"TLS error"); goto done;
        }
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);     // Zertifikat MUSS gültig sein
        mbedtls_ssl_conf_ca_chain(&conf, ca, NULL);
        mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
        mbedtls_ssl_conf_read_timeout(&conf, READ_TIMEOUT_MS);
        if (mbedtls_ssl_setup(&ssl, &conf) != 0 || mbedtls_ssl_set_hostname(&ssl, host.UTF8String) != 0) {
            *err = L(@"TLS error"); goto done;
        }
        mbedtls_ssl_set_bio(&ssl, &net, mbedtls_net_send, mbedtls_net_recv, mbedtls_net_recv_timeout);
        while ((rc = mbedtls_ssl_handshake(&ssl)) != 0) {
            if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            uint32_t flags = mbedtls_ssl_get_verify_result(&ssl);
            if (flags && flags != (uint32_t)-1) {
                char info[256]; mbedtls_x509_crt_verify_info(info, sizeof info, "", flags);
                *err = LF(@"Invalid certificate – connection blocked.\n%s", info);
            } else {
                char e[128]; mbedtls_strerror(rc, e, sizeof e);
                *err = LF(@"Secure connection failed (%s)", e);
            }
            goto done;
        }
        const unsigned char *wp = reqData.bytes; size_t wl = reqData.length, wo = 0;
        while (wo < wl) {
            int w = mbedtls_ssl_write(&ssl, wp + wo, wl - wo);
            if (w == MBEDTLS_ERR_SSL_WANT_READ || w == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (w <= 0) { *err = L(@"Sending failed"); goto done; }
            wo += (size_t)w;
        }
    } else {
        const unsigned char *wp = reqData.bytes; size_t wl = reqData.length, wo = 0;
        while (wo < wl) {
            int w = mbedtls_net_send(&net, wp + wo, wl - wo);
            if (w <= 0) { *err = L(@"Sending failed"); goto done; }
            wo += (size_t)w;
        }
    }

    resp = [NSMutableData data];
    {
        unsigned char buf[16384];
        for (;;) {
            int r = tls ? mbedtls_ssl_read(&ssl, buf, sizeof buf)
                        : mbedtls_net_recv_timeout(&net, buf, sizeof buf, READ_TIMEOUT_MS);
            if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
#ifdef MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET
            if (r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;   // TLS 1.3
#endif
            if (r <= 0) break;
            [resp appendBytes:buf length:(NSUInteger)r];
            if (progress) progress(resp.length);
            if (resp.length > maxBytes + 65536) { *err = L(@"Response too large"); resp = nil; break; }
        }
    }
done:
    if (tls) mbedtls_ssl_close_notify(&ssl);
    mbedtls_net_free(&net); mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf); mbedtls_ctr_drbg_free(&drbg);
    return resp;
}

@implementation RBNet

+ (RBResponse *)fetch:(NSURL *)url maxBytes:(NSUInteger)maxBytes { return [self fetch:url maxBytes:maxBytes progress:nil]; }

+ (RBResponse *)fetch:(NSURL *)url maxBytes:(NSUInteger)maxBytes progress:(void (^)(NSUInteger))progress {
    RBResponse *res = [RBResponse new];
    BOOL allSecure = YES;
    for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
        NSString *scheme = url.scheme.lowercaseString;
        if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) { res.error = L(@"Only http/https is supported"); return res; }
        if (![scheme isEqualToString:@"https"]) allSecure = NO;
        NSString *err = nil;
        NSData *raw = rawRequest(url, maxBytes, &err, progress);
        res.url = url;
        if (!raw) { res.error = err ?: L(@"No response"); return res; }

        NSRange sep = [raw rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, raw.length)];
        if (sep.location == NSNotFound) { res.error = L(@"Invalid response"); return res; }
        NSString *head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, sep.location)] encoding:NSISOLatin1StringEncoding];
        NSData *body = [raw subdataWithRange:NSMakeRange(sep.location + 4, raw.length - sep.location - 4)];
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *st = [lines.firstObject componentsSeparatedByString:@" "];
        int status = st.count > 1 ? [st[1] intValue] : 0;
        NSString *location = nil, *ctype = nil; BOOL chunked = NO;
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange c = [lines[i] rangeOfString:@":"]; if (c.location == NSNotFound) continue;
            NSString *k = [[lines[i] substringToIndex:c.location] lowercaseString];
            NSString *v = [[lines[i] substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([k isEqualToString:@"location"]) location = v;
            else if ([k isEqualToString:@"content-type"]) ctype = v;
            else if ([k isEqualToString:@"transfer-encoding"] && [v.lowercaseString rangeOfString:@"chunked"].location != NSNotFound) chunked = YES;
            else if ([k isEqualToString:@"set-cookie"]) storeCookie(url.host, v);
        }
        if (status >= 300 && status < 400 && location.length) {
            NSURL *next = RBAbsURL(location, url);
            if (!next) { res.error = L(@"Invalid redirect"); return res; }
            url = next; continue;
        }
        res.status = status; res.contentType = ctype;
        res.body = chunked ? dechunk(body) : body;
        if (res.body.length > maxBytes) res.body = [res.body subdataWithRange:NSMakeRange(0, maxBytes)];
        res.secure = allSecure;
        return res;
    }
    res.error = L(@"Too many redirects");
    return res;
}

@end
