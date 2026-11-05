#import <Foundation/Foundation.h>
#import <MediaExtension/MediaExtension.h>

/// Lecture synchrone dans une source d'octets MediaExtension (renvoie le nombre d'octets lus, 0 en cas d'erreur).
size_t QLReadSync(MEByteSource *source, void *dest, size_t length, int64_t offset);
