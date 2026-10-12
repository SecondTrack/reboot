#import "RBAboutView.h"
#import "MeshL10n.h"
#import <QuartzCore/QuartzCore.h>

#define ST_GITHUB @"https://github.com/SecondTrack"
static UIColor* RGB(int r,int g,int b){ return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1]; }

@implementation RBAboutView { UIScrollView *_sc; CGFloat _y; }

+ (void)showIn:(UIView *)host {
    RBAboutView*v=[[RBAboutView alloc] initWithFrame:host.bounds];
    v.frame=CGRectOffset(host.bounds,0,host.bounds.size.height); [host addSubview:v];
    [UIView animateWithDuration:0.3 animations:^{ v.frame=host.bounds; }];
}
- (void)close { [UIView animateWithDuration:0.25 animations:^{ self.frame=CGRectOffset(self.frame,0,self.frame.size.height); } completion:^(BOOL f){ [self removeFromSuperview]; }]; }

- (UILabel *)text:(NSString *)t size:(CGFloat)s bold:(BOOL)b color:(UIColor *)c x:(CGFloat)x w:(CGFloat)w center:(BOOL)ctr in:(UIView *)v {
    UILabel*l=[[UILabel alloc] initWithFrame:CGRectMake(x,_y,w,20)];
    l.text=t; l.font=b?[UIFont boldSystemFontOfSize:s]:[UIFont systemFontOfSize:s]; l.textColor=c; l.numberOfLines=0;
    l.backgroundColor=[UIColor clearColor]; l.textAlignment=ctr?NSTextAlignmentCenter:NSTextAlignmentLeft;
    [l sizeToFit]; l.frame=CGRectMake(x,_y,w,l.frame.size.height); [v addSubview:l]; return l;
}
- (void)button:(NSString *)t filled:(BOOL)filled action:(SEL)sel in:(UIView *)v x:(CGFloat)x w:(CGFloat)w {
    UIButton*b=[UIButton buttonWithType:UIButtonTypeCustom]; b.frame=CGRectMake(x,_y,w,44); b.layer.cornerRadius=22;
    b.titleLabel.font=[UIFont boldSystemFontOfSize:15]; [b setTitle:t forState:UIControlStateNormal];
    if(filled){ b.backgroundColor=RGB(229,37,42); [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; }
    else { b.layer.borderColor=RGB(90,90,96).CGColor; b.layer.borderWidth=1; [b setTitleColor:RGB(245,245,247) forState:UIControlStateNormal]; }
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.5] forState:UIControlStateHighlighted];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside]; [v addSubview:b]; _y+=44;
}

- (id)initWithFrame:(CGRect)f {
    if(!(self=[super initWithFrame:f])) return nil;
    self.backgroundColor=[UIColor blackColor];
    CGFloat W=f.size.width, H=f.size.height;
    UIColor*ink=RGB(245,245,247), *mut=RGB(150,150,156);
    _sc=[[UIScrollView alloc] initWithFrame:self.bounds]; _sc.alwaysBounceVertical=YES; [self addSubview:_sc];
    UIButton*done=[UIButton buttonWithType:UIButtonTypeCustom]; done.frame=CGRectMake(W-84,10,76,32);
    [done setTitle:L(@"Done") forState:UIControlStateNormal]; done.titleLabel.font=[UIFont boldSystemFontOfSize:15];
    [done setTitleColor:ink forState:UIControlStateNormal]; [done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:done];

    _y=44;
    UIImageView*logo=[[UIImageView alloc] initWithImage:[UIImage imageNamed:@"secondtrack"]];
    CGFloat lw=MIN(240,W-60), lh=lw*150/260.0; logo.frame=CGRectMake((W-lw)/2,_y,lw,lh); [_sc addSubview:logo]; _y+=lh+14;
    NSString*ver=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"";
    [self text:LF(@"Reboot Appstore · Version %@",ver) size:13 bold:NO color:mut x:20 w:W-40 center:YES in:_sc]; _y+=24;
    UILabel*t=[self text:L(@"Reboot is the app store by Second Track for old iPods. We give them a second life: used devices, lovingly refurbished – and new apps that make them useful again today.") size:15 bold:NO color:ink x:24 w:W-48 center:YES in:_sc];
    _y+=t.frame.size.height+22;

    // Karte: Open Source
    UIView*card=[[UIView alloc] initWithFrame:CGRectMake(14,_y,W-28,10)]; card.backgroundColor=RGB(22,22,24); card.layer.cornerRadius=14;
    card.layer.borderColor=RGB(48,48,52).CGColor; card.layer.borderWidth=1; [_sc addSubview:card];
    CGFloat cy0=_y, cw=card.bounds.size.width; _y=16;
    [self text:L(@"OPEN SOURCE") size:11 bold:YES color:RGB(229,37,42) x:16 w:cw-32 center:NO in:card]; _y+=18;
    UILabel*os=[self text:L(@"Every app is open source under the GPL-3.0 and lives in its own repository on GitHub. Anyone can read, check and improve the code.") size:14 bold:NO color:ink x:16 w:cw-32 center:NO in:card];
    _y+=os.frame.size.height+12;
    UILabel*sec=[self text:L(@"Safe installs: apps come only over encrypted connections with verified certificates, and every package is checked against its SHA-256 checksum before it is installed.") size:13 bold:NO color:mut x:16 w:cw-32 center:NO in:card];
    _y+=sec.frame.size.height+16;
    [self button:L(@"Source code on GitHub") filled:YES action:@selector(openGitHub) in:card x:16 w:cw-32]; _y+=16;
    card.frame=CGRectMake(14,cy0,W-28,_y); _y=cy0+_y+18;

    UILabel*fine=[self text:L(@"Not affiliated with Apple. iPod is a trademark of Apple Inc.") size:11 bold:NO color:RGB(110,110,116) x:24 w:W-48 center:YES in:_sc];
    _y+=fine.frame.size.height+30;
    _sc.contentSize=CGSizeMake(W,MAX(_y,H+1));
    return self;
}
- (void)openGitHub { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:ST_GITHUB]]; }
@end
