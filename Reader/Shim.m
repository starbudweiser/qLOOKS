#import "Shim.h"

size_t QLReadSync(MEByteSource *source, void *dest, size_t length, int64_t offset) {
    size_t got = 0;
    NSError *error = nil;
    BOOL ok = [source readDataOfLength:length fromOffset:offset toDestination:dest bytesRead:&got error:&error];
    return ok ? got : 0;
}
