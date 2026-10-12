#import "RBStore.h"
#import "RBNet.h"
#import "MeshL10n.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

#define OWNER      @"SecondTrack"
#define CATALOG    @"https://raw.githubusercontent.com/SecondTrack/reboot/main/apps.json"
#define DIR        @"/var/mobile/Library/Reboot"
#define DLDIR      @"/var/mobile/Library/Reboot/dl"
#define RELEASE_TTL (30*60)            // Releases höchstens alle 30 min neu fragen (GitHub erlaubt 60 Anfragen/h)

static NSString* str(id v){ return [v isKindOfClass:[NSString class]]?v:nil; }
static NSString* plainVersion(NSString*v){ v=[v hasPrefix:@"v"]?[v substringFromIndex:1]:v; return [v stringByReplacingOccurrencesOfString:@"+debug" withString:@""]; }

@implementation RBApp
- (BOOL)isInstalled { return self.installedVersion!=nil || self.installedByHand; }
- (BOOL)hasUpdate {
    if(!self.releaseVersion || !self.isInstalled) return NO;
    if(self.installedByHand && !self.installedVersion) return YES;           // per Hand kopiert: Version unbekannt
    return ![plainVersion(self.installedVersion) isEqualToString:plainVersion(self.releaseVersion)];
}
@end

@implementation RBStore {
    NSArray *_apps; RBApp *_store;
    dispatch_queue_t _q;
}
+ (instancetype)shared { static RBStore*s; static dispatch_once_t o; dispatch_once(&o,^{ s=[RBStore new]; }); return s; }
- (id)init {
    if(!(self=[super init])) return nil;
    _q=dispatch_queue_create("reboot.store",DISPATCH_QUEUE_SERIAL);
    [[NSFileManager defaultManager] createDirectoryAtPath:DLDIR withIntermediateDirectories:YES attributes:nil error:NULL];
    [self parseCatalog:[NSData dataWithContentsOfFile:[DIR stringByAppendingPathComponent:@"apps.json"]]];   // letzter Stand sofort
    [self applyReleases:[NSDictionary dictionaryWithContentsOfFile:[DIR stringByAppendingPathComponent:@"releases.plist"]]];
    [self reloadInstalled];
    return self;
}
- (NSArray *)apps { return _apps; }
- (RBApp *)store { return _store; }

#pragma mark - Katalog

// Katalogtexte sind englisch; auf deutschen Geräten gibt es "<feld>_de"
static BOOL gGerman;
static id loc(NSDictionary*d,NSString*k){ id v=gGerman?d[[k stringByAppendingString:@"_de"]]:nil; return v?:d[k]; }
static RBApp* appFrom(NSDictionary*d){
    static dispatch_once_t once; dispatch_once(&once,^{ NSArray*pl=[NSLocale preferredLanguages]; gGerman=pl.count&&[pl[0] hasPrefix:@"de"]; });
    RBApp*a=[RBApp new];
    a.ident=str(d[@"id"]); a.name=str(loc(d,@"name"))?:a.ident; a.shortText=str(loc(d,@"short")); a.text=str(loc(d,@"text"));
    a.category=str(loc(d,@"category")); a.status=str(d[@"status"]); a.package=str(d[@"package"]); a.bundle=str(d[@"bundle"])?:a.package;
    a.iconURL=str(d[@"icon"]); a.requires=str(d[@"requires"]);
    id fe=loc(d,@"features"); a.features=[fe isKindOfClass:[NSArray class]]?fe:@[]; a.ios=[d[@"ios"] isKindOfClass:[NSArray class]]?d[@"ios"]:@[];
    a.isPrivate=[d[@"private"] boolValue];
    // Release-Daten stehen direkt im Katalog -> keine GitHub-API-Abfrage pro App nötig (60/h pro Anschluss!)
    NSDictionary*r=[d[@"release"] isKindOfClass:[NSDictionary class]]?d[@"release"]:nil;
    // Private Repos: GitHub gibt die Dateien ohne Anmeldung nicht heraus (404) -> kein Laden/Update anbieten
    if(r && !a.isPrivate){ a.releaseVersion=plainVersion(str(r[@"version"])?:@""); a.debURL=str(r[@"url"]); a.sha256=str(r[@"sha256"]); a.debSize=[r[@"size"] longLongValue]; }
    return a;
}
- (BOOL)parseCatalog:(NSData *)data {
    id j=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if(![j isKindOfClass:[NSDictionary class]] || ![j[@"apps"] isKindOfClass:[NSArray class]]) return NO;
    NSMutableArray*out=[NSMutableArray array];
    for(id d in j[@"apps"]) if([d isKindOfClass:[NSDictionary class]]){ RBApp*a=appFrom(d); if(a.ident.length && a.package.length) [out addObject:a]; }
    RBApp*st=[j[@"store"] isKindOfClass:[NSDictionary class]]?appFrom(j[@"store"]):nil; st.isStore=YES;
    // Laufzeit-Zustand der alten Objekte übernehmen
    for(RBApp*a in [out arrayByAddingObject:st?:(id)[NSNull null]]) if([a isKindOfClass:[RBApp class]]) for(RBApp*o in [_apps arrayByAddingObject:_store?:(id)[NSNull null]])
        if([o isKindOfClass:[RBApp class]] && [o.ident isEqualToString:a.ident]){
            if(!a.debURL.length){ a.releaseVersion=o.releaseVersion; a.debURL=o.debURL; a.sha256=o.sha256; a.debSize=o.debSize; }
            a.busy=o.busy; a.busyText=o.busyText; }
    _apps=out; _store=st;
    return YES;
}

#pragma mark - Releases

- (void)applyReleases:(NSDictionary *)rel {
    for(RBApp*a in [_apps arrayByAddingObject:_store?:(id)[NSNull null]]){
        if(![a isKindOfClass:[RBApp class]] || a.debURL.length) continue;   // Katalog hat Vorrang
        NSDictionary*r=rel[a.ident]; if(![r isKindOfClass:[NSDictionary class]]) continue;
        a.releaseVersion=str(r[@"version"]); a.debURL=str(r[@"url"]); a.sha256=str(r[@"sha256"]); a.debSize=[r[@"size"] longLongValue];
    }
}
// Neuestes Release einer App: Version, .deb-Adresse, Größe, SHA-256 (aus "digest")
- (NSDictionary *)fetchRelease:(RBApp *)a {
    RBResponse*r=[RBNet fetch:[NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",OWNER,a.ident]] maxBytes:512*1024];
    if(r.error || r.status!=200) return nil;
    id j=[NSJSONSerialization JSONObjectWithData:r.body options:0 error:NULL]; if(![j isKindOfClass:[NSDictionary class]]) return nil;
    for(id as in j[@"assets"]){
        NSString*n=str(as[@"name"]); if(![n hasSuffix:@".deb"]) continue;
        NSString*dg=str(as[@"digest"]); NSString*sha=[dg hasPrefix:@"sha256:"]?[dg substringFromIndex:7]:nil;
        return @{@"version":plainVersion(str(j[@"tag_name"])?:@""),@"url":str(as[@"browser_download_url"])?:@"",@"size":as[@"size"]?:@0,@"sha256":sha?:@""};
    }
    return nil;
}

- (void)refresh:(void(^)(NSString *))done {
    dispatch_async(_q, ^{
        NSString*err=nil;
        // raw.githubusercontent hält "main" bis zu 5 min fest -> aktuellen Commit erfragen und den Katalog
        // genau von diesem Commit laden (nie veraltet). Klappt das nicht (z.B. Anfrage-Limit), wie bisher "main".
        NSString*u=CATALOG;
        RBResponse*ref=[RBNet fetch:[NSURL URLWithString:@"https://api.github.com/repos/SecondTrack/reboot/git/ref/heads/main"] maxBytes:64*1024];
        id rj=(!ref.error && ref.status==200)?[NSJSONSerialization JSONObjectWithData:ref.body options:0 error:NULL]:nil;
        NSString*sha=[rj isKindOfClass:[NSDictionary class]]?str(rj[@"object"][@"sha"]):nil;
        if(sha.length==40) u=[NSString stringWithFormat:@"https://raw.githubusercontent.com/SecondTrack/reboot/%@/apps.json",sha];
        RBResponse*c=[RBNet fetch:[NSURL URLWithString:u] maxBytes:1024*1024];
        if(!c.error && c.status==200 && [self parseCatalogOnMain:c.body]) [c.body writeToFile:[DIR stringByAppendingPathComponent:@"apps.json"] atomically:YES];
        else err=c.error?:[NSString stringWithFormat:@"Katalog: HTTP %d",c.status];
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadInstalled]; if(done) done(err); });
        // Releases (mit Zwischenspeicher, GitHub begrenzt Anfragen)
        NSString*rp=[DIR stringByAppendingPathComponent:@"releases.plist"];
        NSDictionary*old=[NSDictionary dictionaryWithContentsOfFile:rp];
        if(old && [[NSDate date] timeIntervalSince1970]-[old[@"_t"] doubleValue]<RELEASE_TTL && !err) return;
        NSMutableDictionary*rel=[old mutableCopy]?:[NSMutableDictionary dictionary];
        __block NSArray*list=nil; dispatch_sync(dispatch_get_main_queue(), ^{ list=[self->_apps arrayByAddingObject:self->_store?:(id)[NSNull null]]; });
        for(RBApp*a in list){ if(![a isKindOfClass:[RBApp class]] || a.isPrivate || a.debURL.length) continue;
            NSDictionary*r=[self fetchRelease:a]; if(r) rel[a.ident]=r; }
        rel[@"_t"]=@([[NSDate date] timeIntervalSince1970]);
        [rel writeToFile:rp atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyReleases:rel]; if(done) done(nil); });
    });
}
- (BOOL)parseCatalogOnMain:(NSData *)d { __block BOOL ok=NO; dispatch_sync(dispatch_get_main_queue(), ^{ ok=[self parseCatalog:d]; }); return ok; }

#pragma mark - Was ist installiert?

// dpkg-Status (Paket -> Version) + per Hand kopierte Apps (Bundle-ID in /Applications)
- (void)reloadInstalled {
    NSMutableDictionary*dpkg=[NSMutableDictionary dictionary];
    NSString*st=[NSString stringWithContentsOfFile:@"/var/lib/dpkg/status" encoding:NSUTF8StringEncoding error:NULL];
    for(NSString*block in [st componentsSeparatedByString:@"\n\n"]){
        NSString*pkg=nil,*ver=nil; BOOL inst=NO;
        for(NSString*l in [block componentsSeparatedByString:@"\n"]){
            if([l hasPrefix:@"Package: "]) pkg=[l substringFromIndex:9];
            else if([l hasPrefix:@"Version: "]) ver=[l substringFromIndex:9];
            else if([l hasPrefix:@"Status: "]) inst=[l hasSuffix:@" installed"];
        }
        if(pkg && ver && inst) dpkg[pkg]=ver;
    }
    NSMutableSet*bundles=[NSMutableSet set];
    for(NSString*f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Applications" error:NULL]){
        if(![f hasSuffix:@".app"]) continue;
        NSDictionary*pl=[NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/Applications/%@/Info.plist",f]];
        if(str(pl[@"CFBundleIdentifier"])) [bundles addObject:pl[@"CFBundleIdentifier"]];
    }
    for(RBApp*a in [_apps arrayByAddingObject:_store?:(id)[NSNull null]]){
        if(![a isKindOfClass:[RBApp class]]) continue;
        a.installedVersion=dpkg[a.package];
        a.installedByHand=!a.installedVersion && [bundles containsObject:a.bundle];
    }
}

#pragma mark - Installieren

static NSString* sha256Hex(NSData*d){ unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes,(CC_LONG)d.length,h);
    NSMutableString*s=[NSMutableString string]; for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[s appendFormat:@"%02x",h[i]]; return s; }

// setuid-Helfer im App-Bundle starten und auf Ende warten
static int helper(NSArray*args){
    NSString*hp=[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"rbhelper"];
    NSMutableArray*all=[NSMutableArray arrayWithObject:hp]; [all addObjectsFromArray:args];
    char**argv=calloc(all.count+1,sizeof(char*)); for(NSUInteger i=0;i<all.count;i++) argv[i]=(char*)[all[i] fileSystemRepresentation];
    pid_t pid; int rc=posix_spawn(&pid,hp.fileSystemRepresentation,NULL,NULL,argv,environ); free(argv);
    if(rc!=0) return -1;
    int st=0; waitpid(pid,&st,0);
    return WIFEXITED(st)?WEXITSTATUS(st):-1;
}
static NSString* helperError(int rc){
    switch(rc){ case 0: return nil;
        case 3: return L(@"The install helper has no root rights. Please reinstall Reboot once.");
        case 4: return L(@"Package file rejected.");
        case 5: return L(@"This is not a Reboot app – installation refused.");
        case 6: return L(@"dpkg reported an error during installation.");
        default: return LF(@"Install helper missing or crashed (%d).",rc); }
}

- (void)install:(RBApp *)app progress:(void(^)(NSString *))progress done:(void(^)(NSString *))done {
    if(!app.debURL.length){ done(L(@"There is no package for this app yet.")); return; }
    app.busy=YES; NSString*url=app.debURL, *sha=app.sha256, *ver=app.releaseVersion, *pkg=app.package; long long size=app.debSize;
    // iOS soll den Store während Download/Installation nicht einfrieren (Gnadenfrist ~10 min)
    __block UIBackgroundTaskIdentifier bg=[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ [[UIApplication sharedApplication] endBackgroundTask:bg]; bg=UIBackgroundTaskInvalid; }];
    void (^say)(NSString*)=^(NSString*t){ dispatch_async(dispatch_get_main_queue(), ^{ app.busyText=t; if(progress) progress(t); }); };
    void (^finish)(NSString*)=^(NSString*e){ dispatch_async(dispatch_get_main_queue(), ^{ app.busy=NO; app.busyText=nil; [self reloadInstalled]; done(e);
        if(bg!=UIBackgroundTaskInvalid){ [[UIApplication sharedApplication] endBackgroundTask:bg]; bg=UIBackgroundTaskInvalid; } }); };
    dispatch_async(_q, ^{ @autoreleasepool {
        say(L(@"Downloading …"));
        RBResponse*r=[RBNet fetch:[NSURL URLWithString:url] maxBytes:(NSUInteger)MAX(size,1)+1024];
        if(r.error || r.status!=200 || !r.body.length){ finish(r.error?:LF(@"Download failed (HTTP %d from %@)",r.status,r.url.host?:@"?")); return; }
        if(size>0 && (long long)r.body.length!=size){ finish(L(@"Download incomplete – please try again.")); return; }
        say(L(@"Checking …"));
        if(sha.length && ![sha256Hex(r.body) isEqualToString:sha.lowercaseString]){ finish(L(@"Checksum mismatch – package discarded.")); return; }
        NSString*file=[DLDIR stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.deb",pkg,ver]];
        if(![r.body writeToFile:file atomically:YES]){ finish(L(@"Not enough space to save.")); return; }
        say(L(@"Installing …"));
        int rc=helper(@[@"install",file]);
        [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
        finish(helperError(rc));
    }});
}
- (void)remove:(RBApp *)app done:(void(^)(NSString *))done {
    app.busy=YES; app.busyText=L(@"Removing …"); NSString*pkg=app.package;
    dispatch_async(_q, ^{
        int rc=helper(@[@"remove",pkg]);
        dispatch_async(dispatch_get_main_queue(), ^{ app.busy=NO; app.busyText=nil; [self reloadInstalled]; done(helperError(rc)); });
    });
}

#pragma mark - Icons

- (void)icon:(RBApp *)app done:(void(^)(NSData *))done {
    // Dateiname hängt an der Icon-Adresse (Katalog setzt ?v=<Prüfsumme>) -> neues Icon wird neu geladen statt ewig das alte
    NSString*p=[[DIR stringByAppendingPathComponent:@"icons"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%lx.png",app.ident,(unsigned long)app.iconURL.hash]];
    NSData*d=[NSData dataWithContentsOfFile:p]; if(d.length){ done(d); return; }
    if(!app.iconURL.length){ done(nil); return; }
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        RBResponse*r=[RBNet fetch:[NSURL URLWithString:app.iconURL] maxBytes:512*1024];
        NSData*png=(!r.error && r.status==200)?r.body:nil;
        if(png.length){ [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL]; [png writeToFile:p atomically:YES]; }
        dispatch_async(dispatch_get_main_queue(), ^{ done(png); });
    });
}
@end
