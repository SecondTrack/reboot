// RBStore — Katalog und Installation für den Reboot Appstore.
// Katalog: apps.json aus github.com/SecondTrack/reboot. Pro App: neuestes GitHub-Release mit .deb.
// Alles über geprüftes HTTPS (RBNet); jedes Paket wird gegen die SHA-256 aus der GitHub-API geprüft,
// dann installiert der setuid-Helfer (rbhelper) es per dpkg.
#import <Foundation/Foundation.h>

// Eine App im Katalog (Felder aus reboot.json) + Laufzeit-Zustand
@interface RBApp : NSObject
@property (nonatomic, copy) NSString *ident, *name, *shortText, *text, *category, *status, *package, *bundle, *iconURL, *requires;
@property (nonatomic, copy) NSArray *features, *ios;
@property (nonatomic) BOOL isPrivate, isStore;
// Release
@property (nonatomic, copy) NSString *releaseVersion, *debURL, *sha256;   // nil = (noch) kein Release
@property (nonatomic) long long debSize;
// Gerät
@property (nonatomic, copy) NSString *installedVersion;                   // nil = nicht installiert
@property (nonatomic) BOOL installedByHand;                               // App da, aber nicht über dpkg
@property (nonatomic) BOOL busy; @property (nonatomic, copy) NSString *busyText;
@property (nonatomic) float busyProgress;   // 0…1 beim Laden, <0: kein Balken
- (BOOL)isInstalled;
- (BOOL)hasUpdate;
@end

@interface RBStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray *apps;        // ohne den Store selbst
@property (nonatomic, readonly) RBApp *store;         // der Reboot Appstore selbst (Selbst-Update)
// Lädt Katalog + Releases (Netz, sonst Zwischenspeicher). Meldet sich auf dem Main-Thread, ggf. mehrfach.
- (void)refresh:(void(^)(NSString *error))done;
- (void)reloadInstalled;
// Herunterladen, prüfen, installieren. progress-Texte für die Oberfläche. done(nil) = ok.
- (void)install:(RBApp *)app progress:(void(^)(NSString *text))progress done:(void(^)(NSString *error))done;
- (void)remove:(RBApp *)app done:(void(^)(NSString *error))done;
// Icon (Platte, sonst Netz)
- (void)icon:(RBApp *)app done:(void(^)(NSData *png))done;
@end
