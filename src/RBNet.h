// RBNet — sicheres Laden von Webseiten (eigenes TLS 1.2/1.3 via mbedTLS, Zertifikate werden GEPRÜFT).
#import <Foundation/Foundation.h>

@interface RBResponse : NSObject
@property (nonatomic, strong) NSURL *url;            // endgültige URL nach Weiterleitungen
@property (nonatomic) int status;
@property (nonatomic, copy) NSString *contentType;   // z.B. "text/html; charset=utf-8"
@property (nonatomic, strong) NSData *body;
@property (nonatomic) BOOL secure;                   // HTTPS mit gültigem Zertifikat
@property (nonatomic, copy) NSString *error;         // nil = ok
// nur bei download:toFile: — Länge und SHA-256 (hex, klein) genau der in die Datei geschriebenen Bytes
@property (nonatomic) long long bodyLength;
@property (nonatomic, copy) NSString *sha256;
@end

@interface RBNet : NSObject
// Synchron, NICHT auf dem Main-Thread aufrufen. maxBytes begrenzt die Antwortgröße.
+ (RBResponse *)fetch:(NSURL *)url maxBytes:(NSUInteger)maxBytes;
// wie oben; progress meldet die bisher empfangenen Bytes (Hintergrund-Thread)
+ (RBResponse *)fetch:(NSURL *)url maxBytes:(NSUInteger)maxBytes progress:(void (^)(NSUInteger received))progress;
// Lädt den Body direkt in die Datei path (kein Halten im Speicher, chunked wird beim Lesen aufgelöst).
// Datei existiert danach nur bei status 200 ohne error; sonst wird sie gelöscht.
+ (RBResponse *)download:(NSURL *)url toFile:(NSString *)path maxBytes:(NSUInteger)maxBytes progress:(void (^)(NSUInteger received))progress;
@end
