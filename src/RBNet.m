#import "RBNet.h"
#import "MeshL10n.h"
#import "mbedtls/ssl.h"
#import "mbedtls/net_sockets.h"
#import "mbedtls/ctr_drbg.h"
#import "mbedtls/x509_crt.h"
#import "mbedtls/error.h"
#import "psa/crypto.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

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

// ---- Verbindung (TCP + ggf. geprüftes TLS) ----
typedef struct {
    BOOL tls;
    mbedtls_net_context net; mbedtls_ssl_context ssl; mbedtls_ssl_config conf; mbedtls_ctr_drbg_context drbg;
} RBConn;

// Verbindet, prüft das Zertifikat und schickt die GET-Anfrage. connClose() muss IMMER folgen.
static BOOL connOpen(RBConn *c, NSURL *url, NSString **err) {
    c->tls = [url.scheme.lowercaseString isEqualToString:@"https"];
    mbedtls_net_init(&c->net); mbedtls_ssl_init(&c->ssl); mbedtls_ssl_config_init(&c->conf); mbedtls_ctr_drbg_init(&c->drbg);
    BOOL tls = c->tls;
    NSString *host = url.host;
    if (!host.length) { *err = L(@"Invalid address"); return NO; }
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
    int rc;

    if ((rc = mbedtls_net_connect(&c->net, host.UTF8String, port.UTF8String, MBEDTLS_NET_PROTO_TCP)) != 0) {
        *err = L(@"Server not reachable"); return NO;
    }
    {   // Schließt der Server zuerst, darf ein write() die App nicht per SIGPIPE beenden; Senden nicht ewig blockieren
        int one = 1; setsockopt(c->net.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        struct timeval tv = { READ_TIMEOUT_MS / 1000, 0 }; setsockopt(c->net.fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    }
    if (tls) {
        mbedtls_x509_crt *ca = caChain();
        if (!ca) { *err = L(@"Certificate list missing"); return NO; }
        if (mbedtls_ctr_drbg_seed(&c->drbg, rbEntropy, NULL, (const unsigned char *)"rebootst", 6) != 0 ||
            mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
            *err = L(@"TLS error"); return NO;
        }
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);     // Zertifikat MUSS gültig sein
        mbedtls_ssl_conf_ca_chain(&c->conf, ca, NULL);
        mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->drbg);
        mbedtls_ssl_conf_read_timeout(&c->conf, READ_TIMEOUT_MS);
        if (mbedtls_ssl_setup(&c->ssl, &c->conf) != 0 || mbedtls_ssl_set_hostname(&c->ssl, host.UTF8String) != 0) {
            *err = L(@"TLS error"); return NO;
        }
        mbedtls_ssl_set_bio(&c->ssl, &c->net, mbedtls_net_send, mbedtls_net_recv, mbedtls_net_recv_timeout);
        while ((rc = mbedtls_ssl_handshake(&c->ssl)) != 0) {
            if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            uint32_t flags = mbedtls_ssl_get_verify_result(&c->ssl);
            if (flags && flags != (uint32_t)-1) {
                char info[256]; mbedtls_x509_crt_verify_info(info, sizeof info, "", flags);
                *err = LF(@"Invalid certificate – connection blocked.\n%s", info);
            } else {
                char e[128]; mbedtls_strerror(rc, e, sizeof e);
                *err = LF(@"Secure connection failed (%s)", e);
            }
            return NO;
        }
        const unsigned char *wp = reqData.bytes; size_t wl = reqData.length, wo = 0;
        while (wo < wl) {
            int w = mbedtls_ssl_write(&c->ssl, wp + wo, wl - wo);
            if (w == MBEDTLS_ERR_SSL_WANT_READ || w == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (w <= 0) { *err = L(@"Sending failed"); return NO; }
            wo += (size_t)w;
        }
    } else {
        const unsigned char *wp = reqData.bytes; size_t wl = reqData.length, wo = 0;
        while (wo < wl) {
            int w = mbedtls_net_send(&c->net, wp + wo, wl - wo);
            if (w <= 0) { *err = L(@"Sending failed"); return NO; }
            wo += (size_t)w;
        }
    }
    return YES;
}

// Liest das nächste Stück. >0 = Bytes, 0 = Ende/Abbruch/Zeitüberschreitung.
static int connRead(RBConn *c, unsigned char *buf, size_t n) {
    for (;;) {
        int r = c->tls ? mbedtls_ssl_read(&c->ssl, buf, n)
                       : mbedtls_net_recv_timeout(&c->net, buf, n, READ_TIMEOUT_MS);
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
#ifdef MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET
        if (r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;   // TLS 1.3
#endif
        return r > 0 ? r : 0;
    }
}

static void connClose(RBConn *c) {
    if (c->tls) mbedtls_ssl_close_notify(&c->ssl);
    mbedtls_net_free(&c->net); mbedtls_ssl_free(&c->ssl); mbedtls_ssl_config_free(&c->conf); mbedtls_ctr_drbg_free(&c->drbg);
}

// Eine einzelne Anfrage ohne Weiterleitung. Liefert rohe Antwort (Header+Body) oder Fehler.
static NSData *rawRequest(NSURL *url, NSUInteger maxBytes, NSString **err, void (^progress)(NSUInteger)) {
    RBConn c; NSMutableData *resp = nil;
    if (connOpen(&c, url, err)) {
        resp = [NSMutableData data];
        unsigned char buf[16384]; int r;
        while ((r = connRead(&c, buf, sizeof buf)) > 0) {
            [resp appendBytes:buf length:(NSUInteger)r];
            if (progress) progress(resp.length);
            if (resp.length > maxBytes + 65536) { *err = L(@"Response too large"); resp = nil; break; }
        }
    }
    connClose(&c);
    return resp;
}

// Kopfzeilen auswerten: Status, Location, Content-Type, chunked; Cookies werden gemerkt.
static int parseHead(NSData *headData, NSURL *url, NSString **location, NSString **ctype, BOOL *chunked) {
    NSString *head = [[NSString alloc] initWithData:headData encoding:NSISOLatin1StringEncoding];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray *st = [lines.firstObject componentsSeparatedByString:@" "];
    int status = st.count > 1 ? [st[1] intValue] : 0;
    *location = nil; *ctype = nil; *chunked = NO;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange c = [lines[i] rangeOfString:@":"]; if (c.location == NSNotFound) continue;
        NSString *k = [[lines[i] substringToIndex:c.location] lowercaseString];
        NSString *v = [[lines[i] substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:@"location"]) *location = v;
        else if ([k isEqualToString:@"content-type"]) *ctype = v;
        else if ([k isEqualToString:@"transfer-encoding"] && [v.lowercaseString rangeOfString:@"chunked"].location != NSNotFound) *chunked = YES;
        else if ([k isEqualToString:@"set-cookie"]) storeCookie(url.host, v);
    }
    return status;
}

// ---- Streaming-Download: Body direkt in eine Datei, SHA-256 über genau die geschriebenen Bytes ----
typedef struct {
    int fd; CC_SHA256_CTX sha; unsigned long long written, maxBytes;
    // chunked: 0 = Größenzeile, 1 = Daten, 2 = CRLF nach Daten, 3 = fertig
    BOOL chunked; int state; unsigned long long left; char line[64]; size_t ll;
} RBSink;

static NSString *sinkWrite(RBSink *s, const unsigned char *p, size_t n) {
    if (s->written + n > s->maxBytes) return L(@"Response too large");
    size_t o = 0;
    while (o < n) {
        ssize_t w = write(s->fd, p + o, n - o);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return L(@"Not enough space to save.");
        o += (size_t)w;
    }
    CC_SHA256_Update(&s->sha, p, (CC_LONG)n);      // erst nach erfolgreichem Schreiben: Hash = Dateiinhalt
    s->written += n;
    return nil;
}

// Body-Bytes (ggf. chunked) in die Datei; nil = ok
static NSString *sinkFeed(RBSink *s, const unsigned char *p, size_t n) {
    if (!s->chunked) return sinkWrite(s, p, n);
    size_t i = 0;
    while (i < n && s->state != 3) {
        if (s->state == 0) {                         // Größenzeile (hex, Erweiterungen hinter ';' ignoriert)
            unsigned char ch = p[i++];
            if (ch == '\r') continue;
            if (ch != '\n') { if (s->ll >= sizeof s->line - 1) return L(@"Invalid response"); s->line[s->ll++] = (char)ch; continue; }
            s->line[s->ll] = 0; s->ll = 0;
            char *end = NULL; unsigned long long sz = strtoull(s->line, &end, 16);
            if (end == s->line) return L(@"Invalid response");
            if (sz == 0) { s->state = 3; break; }
            if (sz > s->maxBytes) return L(@"Response too large");
            s->left = sz; s->state = 1;
        } else if (s->state == 1) {
            size_t take = (size_t)MIN((unsigned long long)(n - i), s->left);
            NSString *e = sinkWrite(s, p + i, take); if (e) return e;
            i += take; s->left -= take;
            if (!s->left) s->state = 2;
        } else {                                     // CRLF hinter den Chunk-Daten
            unsigned char ch = p[i++];
            if (ch == '\n') s->state = 0;
            else if (ch != '\r') return L(@"Invalid response");
        }
    }
    return nil;
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
        NSData *body = [raw subdataWithRange:NSMakeRange(sep.location + 4, raw.length - sep.location - 4)];
        NSString *location = nil, *ctype = nil; BOOL chunked = NO;
        int status = parseHead([raw subdataWithRange:NSMakeRange(0, sep.location)], url, &location, &ctype, &chunked);
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

+ (RBResponse *)download:(NSURL *)url toFile:(NSString *)path maxBytes:(NSUInteger)maxBytes progress:(void (^)(NSUInteger))progress {
    RBResponse *res = [RBResponse new];
    BOOL allSecure = YES;
    NSData *crlf2 = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    unlink(path.fileSystemRepresentation);
    for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
        NSString *scheme = url.scheme.lowercaseString;
        if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) { res.error = L(@"Only http/https is supported"); return res; }
        if (![scheme isEqualToString:@"https"]) allSecure = NO;
        res.url = url;
        NSString *err = nil, *location = nil, *ctype = nil;
        int status = 0; BOOL inBody = NO, gotHead = NO;
        RBSink s; memset(&s, 0, sizeof s); s.fd = -1; s.maxBytes = maxBytes;
        RBConn c;
        if (connOpen(&c, url, &err)) {
            NSMutableData *head = [NSMutableData data];
            unsigned char buf[16384]; int r;
            while ((r = connRead(&c, buf, sizeof buf)) > 0) {
                const unsigned char *p = buf; size_t n = (size_t)r;
                if (!inBody) {
                    NSUInteger old = head.length, from = old > 3 ? old - 3 : 0;
                    [head appendBytes:buf length:n];
                    NSRange sep = [head rangeOfData:crlf2 options:0 range:NSMakeRange(from, head.length - from)];
                    if (sep.location == NSNotFound) { if (head.length > 65536) { err = L(@"Invalid response"); break; } continue; }
                    gotHead = YES;
                    status = parseHead([head subdataWithRange:NSMakeRange(0, sep.location)], url, &location, &ctype, &s.chunked);
                    if (status != 200) break;                 // Weiterleitung/Fehler: Body wird nicht gebraucht
                    s.fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                    if (s.fd < 0) { err = L(@"Not enough space to save."); break; }
                    CC_SHA256_Init(&s.sha); inBody = YES;
                    size_t off = sep.location + 4 - old;      // Body-Anfang in diesem Puffer
                    p = buf + off; n -= off;
                    head = nil;
                }
                if (n) { err = sinkFeed(&s, p, n); if (err) break; }
                if (progress) progress((NSUInteger)s.written);
                if (s.chunked && s.state == 3) break;
            }
            if (!err && !gotHead) err = L(@"Invalid response");
            if (!err && inBody && s.chunked && s.state != 3) err = L(@"Download incomplete – please try again.");
        }
        connClose(&c);
        if (s.fd >= 0 && close(s.fd) != 0 && !err) err = L(@"Not enough space to save.");
        if (err) { unlink(path.fileSystemRepresentation); res.error = err; return res; }
        if (status >= 300 && status < 400 && location.length) {
            NSURL *next = RBAbsURL(location, url);
            if (!next) { res.error = L(@"Invalid redirect"); return res; }
            url = next; continue;
        }
        res.status = status; res.contentType = ctype; res.secure = allSecure;
        if (status != 200) { unlink(path.fileSystemRepresentation); return res; }
        unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(h, &s.sha);
        NSMutableString *hex = [NSMutableString string];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", h[i]];
        res.bodyLength = (long long)s.written; res.sha256 = hex;
        return res;
    }
    res.error = L(@"Too many redirects");
    return res;
}

@end
