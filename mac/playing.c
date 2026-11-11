// Answers one question through its exit code: is anything playing? 1 yes, 0 no, anything else: unknown.
// Since macOS 15.4 MediaRemote's answer reaches only Apple's own programs, so this library is loaded by /usr/bin/perl, one
// of them (the route of github.com/ungive/mediaremote-adapter). If macOS ever drops perl, the app falls back on Core Audio.
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <unistd.h>

typedef void (*IsPlaying)(dispatch_queue_t, void (^)(bool));

void stt_playing(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    IsPlaying f = h ? (IsPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : 0;
    if (!f) _exit(2);
    f(dispatch_get_global_queue(0, 0), ^(bool playing) { _exit(playing ? 1 : 0); });
    sleep(1);
    _exit(2);
}
