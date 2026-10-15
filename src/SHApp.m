#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "MeshL10n.h"
#import "RBStore.h"
#import "RBAboutView.h"

static UIColor* C(int r,int g,int b){ return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1]; }
#define BG    C(242,242,247)
#define CARD  [UIColor whiteColor]
#define LINE  C(209,209,214)
#define INK   C(0,0,0)
#define MUT   C(142,142,147)
#define IND   C(88,86,214)
#define GRN   C(52,199,89)

// Mitgelieferte Icons/Screenshots (ic/<name>.png, ic/<name>_1.png …) für Apps, die sie haben
static NSString* localKey(RBApp*a){
    NSDictionary*m=@{@"de.mesh.batt":@"batt",@"de.mesh.light":@"light",@"de.mesh.diag":@"diag",@"de.mesh.ios":@"mesh",@"de.mesh.music":@"music"};
    return m[a.package];
}

// Reboot-Logo: Power-Symbol (Kreis mit Lücke oben + senkrechter Strich)
static UIImage* logoMark(CGFloat s, UIColor*c){
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s,s),NO,0);
    CGContextRef ctx=UIGraphicsGetCurrentContext(); [c setStroke];
    CGContextSetLineWidth(ctx,s*0.12f); CGContextSetLineCap(ctx,kCGLineCapRound);
    CGFloat cx=s*0.5f, cy=s*0.54f, r=s*0.3f;
    CGContextAddArc(ctx,cx,cy,r, -M_PI_2+0.5f, -M_PI_2-0.5f+2*M_PI, 0);  // fast voller Kreis, Lücke oben
    CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx,cx,cy-r*1.28f); CGContextAddLineToPoint(ctx,cx,cy-r*0.05f);  // Strich oben
    CGContextStrokePath(ctx);
    UIImage*img=UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); return img;
}
static UIImage* magnifier(CGFloat s, UIColor*c){
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s,s),NO,0);
    CGContextRef ctx=UIGraphicsGetCurrentContext(); [c setStroke];
    CGContextSetLineWidth(ctx,s*0.11f); CGContextSetLineCap(ctx,kCGLineCapRound);
    CGFloat r=s*0.28f, ox=s*0.14f, oy=s*0.14f;
    CGContextStrokeEllipseInRect(ctx,CGRectMake(ox,oy,2*r,2*r));
    CGContextMoveToPoint(ctx,ox+2*r*0.75f,oy+2*r*0.75f); CGContextAddLineToPoint(ctx,s*0.84f,s*0.84f); CGContextStrokePath(ctx);
    UIImage*img=UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); return img;
}
static void launchApp(NSString *bid){
    void*h=dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if(!h) return; int (*f)(CFStringRef,Boolean)=dlsym(h,"SBSLaunchApplicationWithIdentifier"); if(f) f((__bridge CFStringRef)bid,false);
}
// Dekodierte Icons im Speicher halten, damit ein Neuaufbau der Liste nicht jedes PNG neu von Platte liest/dekodiert.
// Bei Speicherwarnung wird der Zwischenspeicher geleert (SHAppDelegate).
static NSCache* iconCache(void){
    static NSCache*c; static dispatch_once_t o; dispatch_once(&o,^{ c=[NSCache new]; c.countLimit=48; });
    return c;
}
// Bild einmal in eine Bitmap zeichnen (gleiche Pixelgröße und Skala), damit das Dekodieren nicht bei jedem Anzeigen passiert
static UIImage* decoded(UIImage*im){
    CGImageRef src=im.CGImage; if(!src) return im;
    size_t w=CGImageGetWidth(src), h=CGImageGetHeight(src); if(!w || !h) return im;
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(NULL,w,h,8,0,cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs); if(!ctx) return im;
    CGContextDrawImage(ctx,CGRectMake(0,0,w,h),src);
    CGImageRef out=CGBitmapContextCreateImage(ctx); CGContextRelease(ctx); if(!out) return im;
    UIImage*r=[UIImage imageWithCGImage:out scale:im.scale orientation:im.imageOrientation]; CGImageRelease(out);
    return r;
}
// Icon: mitgeliefert, sonst aus dem Repo (zwischengespeichert)
static void setIcon(UIImageView*iv, RBApp*a){
    NSString*k=localKey(a); NSString*p=k?[[NSBundle mainBundle] pathForResource:k ofType:@"png" inDirectory:@"ic"]:nil;
    if(p){
        UIImage*im=[iconCache() objectForKey:p];
        if(!im){ im=[UIImage imageWithContentsOfFile:p]; if(im){ im=decoded(im); [iconCache() setObject:im forKey:p]; } }
        iv.image=im; return;
    }
    NSString*key=[NSString stringWithFormat:@"%@|%@",a.ident,a.iconURL?:@""];
    UIImage*hit=[iconCache() objectForKey:key];
    objc_setAssociatedObject(iv,"id",a.ident,OBJC_ASSOCIATION_COPY_NONATOMIC);
    if(hit){ iv.image=hit; return; }
    iv.image=nil;
    [[RBStore shared] icon:a done:^(NSData*png){
        if(!png) return;
        UIImage*im=[iconCache() objectForKey:key];
        if(!im){ UIImage*raw=[UIImage imageWithData:png]; if(raw.CGImage){ im=decoded([UIImage imageWithCGImage:raw.CGImage scale:2 orientation:UIImageOrientationUp]); [iconCache() setObject:im forKey:key]; } }
        if(im && [objc_getAssociatedObject(iv,"id") isEqualToString:a.ident]) iv.image=im; }];
}

// ---- Vorschau-/Screenshot-Kachel (mitgelieferte Bilder, sonst Platzhalter) ----
static UIView* shotTile(RBApp*a, int n, CGRect f){
    NSString*k=localKey(a); NSString*p=k?[[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"%@_%d",k,n] ofType:@"png" inDirectory:@"ic"]:nil;
    UIView*wrap=[[UIView alloc] initWithFrame:f]; wrap.layer.cornerRadius=12; wrap.clipsToBounds=YES; wrap.layer.borderWidth=0.5; wrap.layer.borderColor=LINE.CGColor;
    if(p){ UIImage*im=[UIImage imageWithContentsOfFile:p]; UIImageView*iv=[[UIImageView alloc] initWithFrame:wrap.bounds]; iv.image=im; iv.contentMode=UIViewContentModeScaleAspectFill; [wrap addSubview:iv]; objc_setAssociatedObject(wrap,"img",im,OBJC_ASSOCIATION_RETAIN_NONATOMIC); return wrap; }
    wrap.backgroundColor=[IND colorWithAlphaComponent:0.10];
    UIImageView*ic=[[UIImageView alloc] initWithFrame:CGRectMake(f.size.width/2-26,f.size.height/2-40,52,52)]; ic.layer.cornerRadius=11; ic.clipsToBounds=YES; setIcon(ic,a); [wrap addSubview:ic];
    UILabel*l=[[UILabel alloc] initWithFrame:CGRectMake(0,f.size.height/2+20,f.size.width,18)]; l.text=L(@"Preview"); l.font=[UIFont systemFontOfSize:12]; l.textColor=MUT; l.textAlignment=NSTextAlignmentCenter; l.backgroundColor=[UIColor clearColor]; [wrap addSubview:l];
    return wrap;
}

#define kBusyLabelTag 0x52424C   // Fortschritts-Text im "läuft gerade"-Knopf (wird direkt aktualisiert)
// Nur den Fortschritts-Text ändern, statt alles neu zu bauen. NO = kein passender Text da (dann neu bauen).
static BOOL updateBusyLabel(UIView*host, NSString*text){
    UILabel*l=(UILabel*)[host viewWithTag:kBusyLabelTag];
    if(![l isKindOfClass:[UILabel class]]) return NO;
    if(![l.text isEqualToString:text]) l.text=text;
    return YES;
}

// ---- Aktions-Knopf: Laden / Aktualisieren / Öffnen / läuft gerade ----
@protocol SHActions <NSObject>
- (void)doOpen:(UIButton *)b; - (void)doInstall:(UIButton *)b;
@end
static UIView* actionButton(RBApp*a, CGRect f, id<SHActions> target){
    if(a.busy){
        UIView*v=[[UIView alloc] initWithFrame:f];
        UIActivityIndicatorView*sp=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray]; sp.center=CGPointMake(12,f.size.height/2); [sp startAnimating]; [v addSubview:sp];
        UILabel*l=[[UILabel alloc] initWithFrame:CGRectMake(24,0,f.size.width-24,f.size.height)]; l.tag=kBusyLabelTag; l.text=a.busyText?:@"…"; l.font=[UIFont systemFontOfSize:12]; l.textColor=MUT; l.backgroundColor=[UIColor clearColor]; l.adjustsFontSizeToFitWidth=YES; [v addSubview:l];
        return v;
    }
    UIButton*b=[UIButton buttonWithType:UIButtonTypeCustom]; b.frame=f; b.layer.cornerRadius=f.size.height/2;
    b.titleLabel.font=[UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(b,"app",a,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(a.isPrivate && a.isInstalled){ b.backgroundColor=IND; [b setTitle:L(@"Open") forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; [b addTarget:target action:@selector(doOpen:) forControlEvents:UIControlEventTouchUpInside]; }
    else if(a.hasUpdate){ b.backgroundColor=GRN; [b setTitle:L(@"Update") forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; [b addTarget:target action:@selector(doInstall:) forControlEvents:UIControlEventTouchUpInside]; }
    else if(a.isInstalled){ b.backgroundColor=IND; [b setTitle:L(@"Open") forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; [b addTarget:target action:@selector(doOpen:) forControlEvents:UIControlEventTouchUpInside]; }
    else if(a.debURL.length){ b.backgroundColor=CARD; b.layer.borderWidth=1.5; b.layer.borderColor=IND.CGColor; [b setTitle:L(@"Install") forState:UIControlStateNormal]; [b setTitleColor:IND forState:UIControlStateNormal]; [b addTarget:target action:@selector(doInstall:) forControlEvents:UIControlEventTouchUpInside]; }
    else { b.backgroundColor=C(233,233,238); [b setTitle:(a.isPrivate?L(@"Private"):L(@"Soon")) forState:UIControlStateNormal]; [b setTitleColor:MUT forState:UIControlStateNormal]; b.enabled=NO; }
    return b;
}
// redraw: alles neu zeichnen; tick: nur Fortschritts-Text (fällt selbst auf redraw zurück)
static void runInstall(RBApp*a, void(^redraw)(void), void(^tick)(NSString*)){
    [[RBStore shared] install:a progress:^(NSString*t){ tick(t); } done:^(NSString*e){
        redraw();
        if(e) [[[UIAlertView alloc] initWithTitle:a.name message:e delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    }];
    redraw();
}

// ================= Detail-Seite =================
@interface SHDetailController : UIViewController <SHActions, UIAlertViewDelegate>
@property(nonatomic,strong) RBApp *app;
@end
@implementation SHDetailController {
    UIScrollView *_sc; UIView *_btnHost;
}
- (void)loadView {
    self.view=[[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds]; self.view.backgroundColor=BG;
    CGFloat W=self.view.bounds.size.width;
    UIButton*back=[UIButton buttonWithType:UIButtonTypeCustom]; back.frame=CGRectMake(8,16,110,34);
    [back setTitle:@"‹ Reboot" forState:UIControlStateNormal]; [back setTitleColor:IND forState:UIControlStateNormal];
    back.titleLabel.font=[UIFont systemFontOfSize:17]; back.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
    [back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:back];
    UIScrollView*sc=[[UIScrollView alloc] initWithFrame:CGRectMake(0,54,W,self.view.bounds.size.height-54)]; sc.alwaysBounceVertical=YES; sc.contentInset=UIEdgeInsetsMake(0,0,48,0); [self.view addSubview:sc]; _sc=sc;

    // Kopf: Icon + Name + Button
    UIImageView*ic=[[UIImageView alloc] initWithFrame:CGRectMake(16,16,74,74)]; ic.layer.cornerRadius=16; ic.clipsToBounds=YES; ic.backgroundColor=C(230,230,235); setIcon(ic,_app); [sc addSubview:ic];
    UILabel*nm=[[UILabel alloc] initWithFrame:CGRectMake(102,18,W-102-16,26)]; nm.text=_app.name; nm.font=[UIFont boldSystemFontOfSize:22]; nm.textColor=INK; nm.backgroundColor=[UIColor clearColor]; [sc addSubview:nm];
    UILabel*ds=[[UILabel alloc] initWithFrame:CGRectMake(102,44,W-102-16,30)]; ds.text=_app.shortText; ds.numberOfLines=2; ds.font=[UIFont systemFontOfSize:12]; ds.textColor=MUT; ds.backgroundColor=[UIColor clearColor]; [sc addSubview:ds];
    _btnHost=[[UIView alloc] initWithFrame:CGRectMake(102,76,W-102-16,32)]; [sc addSubview:_btnHost];
    [self drawButton];

    // Version / Installiert
    CGFloat y=120;
    NSMutableArray*meta=[NSMutableArray array];
    if(_app.releaseVersion) [meta addObject:LF(@"Version %@",_app.releaseVersion)];
    if(_app.installedVersion && _app.hasUpdate) [meta addObject:LF(@"installed: %@",_app.installedVersion)];
    if(_app.ios.count) [meta addObject:[@"iOS " stringByAppendingString:[_app.ios componentsJoinedByString:@" / "]]];
    if(_app.requires.length) [meta addObject:LF(@"needs %@",_app.requires)];
    if(meta.count){ UILabel*m=[[UILabel alloc] initWithFrame:CGRectMake(16,y,W-32,16)]; m.text=[meta componentsJoinedByString:@" · "]; m.font=[UIFont systemFontOfSize:12]; m.textColor=MUT; m.backgroundColor=[UIColor clearColor]; m.adjustsFontSizeToFitWidth=YES; [sc addSubview:m]; y+=26; }

    // Screenshots: nur echte, mitgelieferte Bilder. Ohne Bilder gibt es keinen Vorschau-Bereich (keine Platzhalter).
    NSString*k=localKey(_app); NSMutableArray*shots=[NSMutableArray array];
    for(int i=1;i<=6 && k;i++) if([[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"%@_%d",k,i] ofType:@"png" inDirectory:@"ic"]) [shots addObject:@(i)];
    CGFloat dy=y;
    if(shots.count){
        UILabel*sh=[[UILabel alloc] initWithFrame:CGRectMake(16,y,W-32,18)]; sh.text=L(@"Preview"); sh.font=[UIFont boldSystemFontOfSize:15]; sh.textColor=INK; sh.backgroundColor=[UIColor clearColor]; [sc addSubview:sh];
        UIScrollView*gal=[[UIScrollView alloc] initWithFrame:CGRectMake(0,y+26,W,228)]; gal.showsHorizontalScrollIndicator=NO; [sc addSubview:gal];
        CGFloat sx=16, sw=148, shh=222;
        for(NSNumber*i in shots){
            UIView*tile=shotTile(_app,i.intValue,CGRectMake(sx,3,sw,shh));
            [tile addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomShot:)]]; tile.userInteractionEnabled=YES;
            [gal addSubview:tile]; sx+=sw+12;
        }
        gal.contentSize=CGSizeMake(sx,shh);
        dy=y+26+228+16;
    }

    // Beschreibung + Funktionen
    UILabel*bt=[[UILabel alloc] initWithFrame:CGRectMake(16,dy,W-32,18)]; bt.text=L(@"Description"); bt.font=[UIFont boldSystemFontOfSize:15]; bt.textColor=INK; bt.backgroundColor=[UIColor clearColor]; [sc addSubview:bt];
    NSMutableString*body=[NSMutableString stringWithString:_app.text?:_app.shortText?:@""];
    if(_app.features.count){ [body appendString:@"\n"]; for(NSString*f in _app.features) [body appendFormat:@"\n•  %@",f]; }
    UILabel*lg=[[UILabel alloc] init]; lg.text=body; lg.numberOfLines=0; lg.font=[UIFont systemFontOfSize:14]; lg.textColor=C(60,60,67); lg.backgroundColor=[UIColor clearColor];
    CGSize sz=[lg.text sizeWithFont:lg.font constrainedToSize:CGSizeMake(W-32,9999) lineBreakMode:NSLineBreakByWordWrapping];
    lg.frame=CGRectMake(16,dy+24,W-32,sz.height); [sc addSubview:lg];
    CGFloat ey=dy+24+sz.height+24;
    // Entfernen (nur über Reboot installierte Apps, nicht der Store selbst)
    if(_app.installedVersion && !_app.isStore){
        UIButton*rm=[UIButton buttonWithType:UIButtonTypeCustom]; rm.frame=CGRectMake(16,ey,W-32,40);
        [rm setTitle:L(@"Remove app") forState:UIControlStateNormal]; [rm setTitleColor:C(255,59,48) forState:UIControlStateNormal]; rm.titleLabel.font=[UIFont systemFontOfSize:15];
        rm.backgroundColor=CARD; rm.layer.cornerRadius=10; [rm addTarget:self action:@selector(askRemove) forControlEvents:UIControlEventTouchUpInside]; [sc addSubview:rm]; ey+=56;
    }
    sc.contentSize=CGSizeMake(W,ey+10);
}
- (void)drawButton {
    for(UIView*v in [_btnHost.subviews copy]) [v removeFromSuperview];
    [_btnHost addSubview:actionButton(_app,CGRectMake(0,0,120,32),self)];
}
- (void)goBack { [self.navigationController popViewControllerAnimated:YES]; }
- (void)zoomShot:(UITapGestureRecognizer *)g {
    UIImage*img=objc_getAssociatedObject(g.view,"img"); if(!img) return;
    UIWindow*w=[[UIApplication sharedApplication] keyWindow];
    UIView*ov=[[UIView alloc] initWithFrame:w.bounds]; ov.backgroundColor=[UIColor blackColor]; ov.alpha=0;
    UIImageView*iv=[[UIImageView alloc] initWithFrame:CGRectInset(ov.bounds,0,20)]; iv.image=img; iv.contentMode=UIViewContentModeScaleAspectFit; [ov addSubview:iv];
    UILabel*hint=[[UILabel alloc] initWithFrame:CGRectMake(0,ov.bounds.size.height-26,ov.bounds.size.width,18)]; hint.text=L(@"Tap to close"); hint.font=[UIFont systemFontOfSize:12]; hint.textColor=[UIColor colorWithWhite:1 alpha:0.5]; hint.textAlignment=NSTextAlignmentCenter; hint.backgroundColor=[UIColor clearColor]; [ov addSubview:hint];
    [ov addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeZoom:)]];
    [w addSubview:ov]; [UIView animateWithDuration:0.2 animations:^{ ov.alpha=1; }];
}
- (void)closeZoom:(UITapGestureRecognizer *)g { UIView*ov=g.view; [UIView animateWithDuration:0.2 animations:^{ ov.alpha=0; } completion:^(BOOL f){ [ov removeFromSuperview]; }]; }
- (void)doOpen:(UIButton *)b { launchApp(_app.bundle); }
- (void)doInstall:(UIButton *)b { __weak SHDetailController*ws=self; runInstall(_app,^{ [ws drawButton]; },^(NSString*t){ [ws progressText:t]; }); }
- (void)progressText:(NSString *)t { if(!_app.busy || !updateBusyLabel(_btnHost,t)) [self drawButton]; }
- (void)askRemove {
    UIAlertView*a=[[UIAlertView alloc] initWithTitle:_app.name message:L(@"Remove this app from your iPod?") delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Remove"),nil]; [a show];
}
- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)i {
    if(i==av.cancelButtonIndex) return;
    __weak SHDetailController*ws=self;
    [[RBStore shared] remove:_app done:^(NSString*e){
        if(e) [[[UIAlertView alloc] initWithTitle:ws.app.name message:e delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        [ws goBack];
    }];
    [self drawButton];
}
@end

// ================= Liste + Suche =================
@interface SHListController : UIViewController <UITextFieldDelegate, UIScrollViewDelegate, SHActions>
@end
@implementation SHListController {
    UITextField *_searchField; UIScrollView *_sc; NSString *_filter; UILabel *_status; BOOL _loading;
}
- (void)loadView {
    self.view=[[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds]; self.view.backgroundColor=BG;
    CGFloat W=self.view.bounds.size.width;
    _filter=@"";

    // Header: Logo + große Wortmarke + Untertitel
    UIImageView*lg=[[UIImageView alloc] initWithFrame:CGRectMake(16,27,30,30)]; lg.image=logoMark(30,IND); [self.view addSubview:lg];
    UILabel*title=[[UILabel alloc] initWithFrame:CGRectMake(54,22,W-70,40)]; title.text=@"Reboot"; title.font=[UIFont boldSystemFontOfSize:30]; title.textColor=INK; title.backgroundColor=[UIColor clearColor]; [self.view addSubview:title];
    // ⓘ oben rechts: Über Reboot
    UIButton*info=[UIButton buttonWithType:UIButtonTypeCustom]; info.frame=CGRectMake(W-52,22,40,40);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26,26),NO,0); [IND set];
    UIBezierPath*ring=[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1.5,1.5,23,23)]; ring.lineWidth=2; [ring stroke];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(11.5,6,3,3)] fill]; [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(11.75,10.5,2.5,9.5) cornerRadius:1] fill];
    [info setImage:UIGraphicsGetImageFromCurrentImageContext() forState:UIControlStateNormal]; UIGraphicsEndImageContext();
    [info addTarget:self action:@selector(showAbout) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:info];

    _status=[[UILabel alloc] initWithFrame:CGRectMake(16,64,W-32,18)]; _status.text=L(@"Apps for your iPod"); _status.font=[UIFont systemFontOfSize:14]; _status.textColor=MUT; _status.backgroundColor=[UIColor clearColor]; [self.view addSubview:_status];

    // schlanke Such-Pille statt iOS-6-UISearchBar
    _searchField=[[UITextField alloc] initWithFrame:CGRectMake(16,92,W-32,38)];
    _searchField.backgroundColor=C(233,233,238); _searchField.layer.cornerRadius=19; _searchField.font=[UIFont systemFontOfSize:15];
    _searchField.placeholder=L(@"Search"); _searchField.textColor=INK;
    _searchField.clearButtonMode=UITextFieldViewModeWhileEditing; _searchField.returnKeyType=UIReturnKeySearch;
    _searchField.autocorrectionType=UITextAutocorrectionTypeNo; _searchField.autocapitalizationType=UITextAutocapitalizationTypeNone; _searchField.delegate=self;
    _searchField.contentVerticalAlignment=UIControlContentVerticalAlignmentCenter;
    UIView*lv=[[UIView alloc] initWithFrame:CGRectMake(0,0,36,38)]; UIImageView*mag=[[UIImageView alloc] initWithFrame:CGRectMake(12,11,16,16)]; mag.image=magnifier(16,MUT); [lv addSubview:mag];
    _searchField.leftView=lv; _searchField.leftViewMode=UITextFieldViewModeAlways;
    [_searchField addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:_searchField];

    _sc=[[UIScrollView alloc] initWithFrame:CGRectMake(0,142,W,self.view.bounds.size.height-142)];
    _sc.alwaysBounceVertical=YES; _sc.contentInset=UIEdgeInsetsMake(0,0,44,0); _sc.delegate=self; [self.view addSubview:_sc];
    UITapGestureRecognizer*dismiss=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideKb)];
    dismiss.cancelsTouchesInView=NO; [self.view addGestureRecognizer:dismiss];
    [self build];
    [self refresh];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:UIApplicationWillEnterForegroundNotification object:nil];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [[RBStore shared] reloadInstalled]; [self build]; }
- (void)showAbout { [RBAboutView showIn:self.view.window]; }

// Katalog + Releases holen (zeigt sofort den letzten Stand)
- (void)refresh {
    if(_loading) return; _loading=YES; _status.text=L(@"Checking for apps and updates …");
    __weak SHListController*ws=self;
    [[RBStore shared] refresh:^(NSString*err){
        SHListController*s=ws; if(!s) return;
        s->_loading=NO;
        NSInteger up=0; for(RBApp*a in [RBStore shared].apps) if(a.hasUpdate) up++;
        if([RBStore shared].store.hasUpdate) up++;
        s->_status.text=err?L(@"Offline – showing the last known list"):(up?LF(@"%ld updates available",(long)up):L(@"Apps for your iPod"));
        [s build];
    }];
}

- (NSArray *)filtered {
    NSArray*all=[RBStore shared].apps?:@[];
    if(!_filter.length) return all;
    NSMutableArray*r=[NSMutableArray array]; NSString*f=[_filter lowercaseString];
    for(RBApp*a in all) if([[a.name lowercaseString] rangeOfString:f].location!=NSNotFound || [[a.shortText lowercaseString] rangeOfString:f].location!=NSNotFound || [[a.category lowercaseString] rangeOfString:f].location!=NSNotFound) [r addObject:a];
    return r;
}
- (void)searchChanged:(UITextField *)tf { _filter=tf.text?:@""; [self build]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)hideKb { [_searchField resignFirstResponder]; }
- (void)scrollViewWillBeginDragging:(UIScrollView *)s { [_searchField resignFirstResponder]; }

- (void)addCard:(RBApp *)a y:(CGFloat *)y {
    CGFloat W=_sc.bounds.size.width, ch=78;
    UIView*card=[[UIView alloc] initWithFrame:CGRectMake(14,*y,W-28,ch)];
    card.backgroundColor=CARD; card.layer.cornerRadius=14; card.layer.borderWidth=0.5; card.layer.borderColor=LINE.CGColor;
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openDetail:)]]; card.userInteractionEnabled=YES;
    objc_setAssociatedObject(card,"app",a,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [_sc addSubview:card];
    UIImageView*ic=[[UIImageView alloc] initWithFrame:CGRectMake(13,13,52,52)]; ic.layer.cornerRadius=11; ic.clipsToBounds=YES; ic.backgroundColor=C(230,230,235); setIcon(ic,a); [card addSubview:ic];
    CGFloat btnW=100, btnX=card.bounds.size.width-btnW-12;
    [card addSubview:actionButton(a, CGRectMake(btnX,23,btnW,32), self)];
    CGFloat txtW=btnX-78-10;   // Text endet VOR dem Button
    UILabel*nm=[[UILabel alloc] initWithFrame:CGRectMake(78,15,txtW,22)]; nm.text=a.name; nm.font=[UIFont boldSystemFontOfSize:17]; nm.textColor=INK; nm.backgroundColor=[UIColor clearColor]; [card addSubview:nm];
    UILabel*ds=[[UILabel alloc] initWithFrame:CGRectMake(78,39,txtW,34)]; ds.text=a.shortText; ds.numberOfLines=2; ds.font=[UIFont systemFontOfSize:12]; ds.textColor=MUT; ds.backgroundColor=[UIColor clearColor]; [card addSubview:ds];
    *y+=ch+12;
}
- (void)build {
    for(UIView*v in [_sc.subviews copy]) [v removeFromSuperview];
    CGFloat W=_sc.bounds.size.width, y=8;
    // Selbst-Update des Stores ganz oben
    RBApp*st=[RBStore shared].store;
    if(st.hasUpdate && !_filter.length){ [self addCard:st y:&y]; }
    NSArray*list=[self filtered];
    for(RBApp*a in list) [self addCard:a y:&y];
    if(list.count==0){ UILabel*e=[[UILabel alloc] initWithFrame:CGRectMake(0,40,W,20)]; e.text=_loading?L(@"Loading …"):L(@"Nothing found"); e.textColor=MUT; e.textAlignment=NSTextAlignmentCenter; e.font=[UIFont systemFontOfSize:14]; e.backgroundColor=[UIColor clearColor]; [_sc addSubview:e]; y+=60; }
    _sc.contentSize=CGSizeMake(W,y+20);
}
- (void)openDetail:(UITapGestureRecognizer *)g {
    SHDetailController*d=[[SHDetailController alloc] init]; d.app=objc_getAssociatedObject(g.view,"app"); [self.navigationController pushViewController:d animated:YES];
}
- (void)doOpen:(UIButton *)b { launchApp(((RBApp*)objc_getAssociatedObject(b,"app")).bundle); }
- (void)doInstall:(UIButton *)b {
    __weak SHListController*ws=self; RBApp*a=objc_getAssociatedObject(b,"app"); NSString*ident=a.ident;
    runInstall(a,^{ [ws build]; },^(NSString*t){ [ws progressText:t forApp:ident]; });
}
// Fortschritt: nur den Text auf der Karte dieser App ändern (Karten-App kann nach Katalog-Neuladen ein neues Objekt sein)
- (void)progressText:(NSString *)t forApp:(NSString *)ident {
    for(UIView*card in _sc.subviews){
        RBApp*ca=objc_getAssociatedObject(card,"app");
        if(![ca.ident isEqualToString:ident]) continue;
        if(ca.busy && updateBusyLabel(card,t)) return;
        break;
    }
    [self build];
}
@end

@interface SHAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SHAppDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    [a setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
    self.window=[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController*nav=[[UINavigationController alloc] initWithRootViewController:[[SHListController alloc] init]];
    nav.navigationBarHidden=YES;  // eigener Header pro Seite statt iOS-6-Leiste
    self.window.rootViewController=nav;
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)a { [iconCache() removeAllObjects]; }
@end
