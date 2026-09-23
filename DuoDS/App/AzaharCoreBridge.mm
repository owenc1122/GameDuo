#import "AzaharCoreBridge.h"
#include "PSPFrameRatePolicy.h"
#import <Accelerate/Accelerate.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <mach/mach.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <map>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <vector>

#include "../../ThirdParty/Azahar/externals/libretro-common/libretro-common/include/libretro.h"

extern "C" {
void retro_set_environment(retro_environment_t);
void retro_set_video_refresh(retro_video_refresh_t);
void retro_set_audio_sample(retro_audio_sample_t);
void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
void retro_set_input_poll(retro_input_poll_t);
void retro_set_input_state(retro_input_state_t);
void retro_init(void);
void retro_deinit(void);
bool retro_load_game(const struct retro_game_info *);
void retro_unload_game(void);
void retro_run(void);
void retro_get_system_av_info(struct retro_system_av_info *);
void* retro_get_memory_data(unsigned);
size_t retro_get_memory_size(unsigned);
size_t retro_serialize_size(void);
bool retro_serialize(void *, size_t);
bool retro_unserialize(const void *, size_t);
void retro_cheat_reset(void);
void retro_cheat_set(unsigned, bool, const char *);
int duo_install_cia(const char*, char*, size_t, uint64_t*);
}

namespace {

struct CoreAPI {
    decltype(&retro_set_environment) retro_set_environment = &::retro_set_environment;
    decltype(&retro_set_video_refresh) retro_set_video_refresh = &::retro_set_video_refresh;
    decltype(&retro_set_audio_sample) retro_set_audio_sample = &::retro_set_audio_sample;
    decltype(&retro_set_audio_sample_batch) retro_set_audio_sample_batch = &::retro_set_audio_sample_batch;
    decltype(&retro_set_input_poll) retro_set_input_poll = &::retro_set_input_poll;
    decltype(&retro_set_input_state) retro_set_input_state = &::retro_set_input_state;
    decltype(&retro_init) retro_init = &::retro_init;
    decltype(&retro_deinit) retro_deinit = &::retro_deinit;
    decltype(&retro_load_game) retro_load_game = &::retro_load_game;
    decltype(&retro_unload_game) retro_unload_game = &::retro_unload_game;
    decltype(&retro_run) retro_run = &::retro_run;
    decltype(&retro_get_system_av_info) retro_get_system_av_info = &::retro_get_system_av_info;
    decltype(&retro_get_memory_data) retro_get_memory_data = &::retro_get_memory_data;
    decltype(&retro_get_memory_size) retro_get_memory_size = &::retro_get_memory_size;
    decltype(&retro_serialize_size) retro_serialize_size = &::retro_serialize_size;
    decltype(&retro_serialize) retro_serialize = &::retro_serialize;
    decltype(&retro_unserialize) retro_unserialize = &::retro_unserialize;
    decltype(&retro_cheat_reset) retro_cheat_reset = &::retro_cheat_reset;
    decltype(&retro_cheat_set) retro_cheat_set = &::retro_cheat_set;
} api;
bool n64Core = false;
bool ndsCore = false;
bool pspCore = false;
NSURL *n64SaveURL = nil;
void *n64Library = nullptr;
void *melonDSLibrary = nullptr;
void *deSmuMELibrary = nullptr;
void *ppssppLibrary = nullptr;
void *selectedCoreLibrary = nullptr;
std::map<std::string, std::string> configuredOptions;

bool bindCoreAPI(void *library, CoreAPI& target) {
    if (!library) return false;
#define BIND_REQUIRED(symbol) \
    target.symbol = reinterpret_cast<decltype(target.symbol)>(dlsym(library, #symbol)); \
    if (!target.symbol) return false
    BIND_REQUIRED(retro_set_environment);
    BIND_REQUIRED(retro_set_video_refresh);
    BIND_REQUIRED(retro_set_audio_sample);
    BIND_REQUIRED(retro_set_audio_sample_batch);
    BIND_REQUIRED(retro_set_input_poll);
    BIND_REQUIRED(retro_set_input_state);
    BIND_REQUIRED(retro_init);
    BIND_REQUIRED(retro_deinit);
    BIND_REQUIRED(retro_load_game);
    BIND_REQUIRED(retro_unload_game);
    BIND_REQUIRED(retro_run);
    BIND_REQUIRED(retro_get_system_av_info);
    BIND_REQUIRED(retro_get_memory_data);
    BIND_REQUIRED(retro_get_memory_size);
    BIND_REQUIRED(retro_serialize_size);
    BIND_REQUIRED(retro_serialize);
    BIND_REQUIRED(retro_unserialize);
    BIND_REQUIRED(retro_cheat_reset);
    BIND_REQUIRED(retro_cheat_set);
#undef BIND_REQUIRED
    return true;
}

bool selectCore(bool n64, bool nds = false, bool psp = false) {
    api = CoreAPI{};
    n64Core = n64;
    ndsCore = nds;
    pspCore = psp;
    selectedCoreLibrary = nullptr;
    if (!n64 && !nds && !psp) return true;
    const bool useDeSmuME = nds && configuredOptions["duo_nds_core"] == "desmume";
    void *&library = psp ? ppssppLibrary : n64 ? n64Library : (useDeSmuME ? deSmuMELibrary : melonDSLibrary);
    if (!library) {
        NSString *frameworkName = psp ? @"PPSSPPCore.framework" : nds
            ? (useDeSmuME ? @"DeSmuMECore.framework" : @"MelonDSCore.framework")
            : @"N64Core.framework";
        NSString *frameworkPath = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:frameworkName];
        NSString *path = [frameworkPath stringByAppendingPathComponent:frameworkName.lastPathComponent.stringByDeletingPathExtension];
        library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        if (nds && !library && !useDeSmuME) {
            frameworkPath = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"DeSmuMECore.framework"];
            path = [frameworkPath stringByAppendingPathComponent:@"DeSmuMECore"];
            library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        }
    }
    if (!library) return false;
    selectedCoreLibrary = library;
    return bindCoreAPI(library, api);
}

void unloadSelectedCoreLibrary() {
    if (!selectedCoreLibrary) return;
    void *library = selectedCoreLibrary;
    selectedCoreLibrary = nullptr;
    api = CoreAPI{};
    if (library == n64Library) n64Library = nullptr;
    if (library == melonDSLibrary) melonDSLibrary = nullptr;
    if (library == deSmuMELibrary) deSmuMELibrary = nullptr;
    if (library == ppssppLibrary) ppssppLibrary = nullptr;
    dlclose(library);
}

NSString * const AzaharBridgeErrorDomain = @"com.duods.azahar";
AzaharCoreBridge *activeBridge = nil;
std::mutex stateMutex;
std::array<bool, 32> buttonStates{};
std::array<int16_t, 2> circlePad{};
std::array<int16_t, 2> touchPosition{};
bool touchPressed = false;
std::vector<int16_t> audioFrameBuffer;
#if DEBUG
bool touchWasObserved = false;
std::array<bool, 32> buttonWasObserved{};
#endif
bool shutdownRequested = false;
std::map<std::string, std::string> optionValues;
std::string systemDirectoryPath;
std::string saveDirectoryPath;
std::string lastCoreMessage;
retro_pixel_format pixelFormat = RETRO_PIXEL_FORMAT_XRGB8888;

// PSP owns an offscreen ES3 context on the serial emulation queue. SceneKit
// keeps its separate Metal renderer; never make this context current on the UI.
EAGLContext *pspGLContext = nil;
retro_hw_render_callback pspHW{};
GLuint pspFramebuffer = 0, pspColor = 0, pspDepth = 0;
unsigned pspWidth = 0, pspHeight = 0;
bool pspContextReady = false;
CVOpenGLESTextureCacheRef pspTextureCache = nullptr;
CVPixelBufferPoolRef pspPixelPool = nullptr;
CVPixelBufferRef pspSurface = nullptr;
CVOpenGLESTextureRef pspSurfaceTexture = nullptr;
std::vector<uint8_t> pspReadback;
std::vector<uint8_t> pspPreviousPixels;
#if DEBUG
unsigned pspNewImages = 0;
bool pspPortableReadback = false;
double pspReadbackSeconds = 0, pspCopySeconds = 0;
#endif

// Optional, versioned-by-symbol frontend extension. If an older core is
// installed, High safely stays at the original game's timing.
void (*pspSetHighFrameRate)(bool) = nullptr;
uint64_t (*pspDisplayCounters)() = nullptr;
unsigned (*pspClockStatus)() = nullptr;
void (*pspDisableAntialias)() = nullptr;
unsigned pspAAWindows = 0, pspAABusyWindows = 0;
bool pspAADisabledForLoad = false;
PSPFrameRatePolicy pspFramePolicy;
double pspPolicyWindowStart = 0, pspPolicyLastFrame = 0, pspPolicyWork = 0;
uint64_t pspPolicyCounters = 0;
unsigned pspPolicyFrames = 0, pspPolicyLate = 0;

void resetPSPFrameWindow(double now) {
    pspPolicyWindowStart = now;
    pspPolicyWork = 0;
    pspPolicyFrames = pspPolicyLate = 0;
    pspPolicyCounters = pspDisplayCounters ? pspDisplayCounters() : 0;
}

void updatePSPFramePolicy(double start, double now, double budget) {
    if (!pspDisplayCounters || !pspSetHighFrameRate || !pspClockStatus) return;
    if (pspPolicyWindowStart == 0 || start - pspPolicyLastFrame > 0.25) resetPSPFrameWindow(start);
    pspPolicyLastFrame = now;
    pspPolicyWork += now - start;
    ++pspPolicyFrames;
    if (now - start > budget) ++pspPolicyLate;
    const double elapsed = now - pspPolicyWindowStart;
    if (elapsed < 4) return;
    const uint64_t counters = pspDisplayCounters();
    const uint32_t vblanks = (uint32_t)(counters >> 32) - (uint32_t)(pspPolicyCounters >> 32);
    const uint32_t flips = (uint32_t)counters - (uint32_t)pspPolicyCounters;
    if (vblanks > 1000 || flips > 1000) { resetPSPFrameWindow(now); return; } // State load/reset.
    const auto before = pspFramePolicy.state;
    const bool hot = NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
    const unsigned clockStatus = pspClockStatus();
    pspFramePolicy.sample(flips / elapsed, vblanks / elapsed,
                          pspPolicyWork / (pspPolicyFrames * budget),
                          (double)pspPolicyLate / pspPolicyFrames, hot,
                          clockStatus > 0 && !(clockStatus & 0x80000000u));
    if (before != pspFramePolicy.state) pspSetHighFrameRate(pspFramePolicy.boosted());
    // AA is optional; simulation speed and frame pacing take priority. Allow
    // boot/shader warm-up, then retire the filter on sustained budget pressure.
    // Don't toggle it back and forth during play.
    if (pspDisableAntialias && !pspAADisabledForLoad && ++pspAAWindows > 2) {
        const bool busy = hot || pspPolicyWork / (pspPolicyFrames * budget) > 0.85;
        pspAABusyWindows = busy ? pspAABusyWindows + 1 : 0;
        if (hot || pspAABusyWindows >= 2) {
            pspDisableAntialias();
            pspAADisabledForLoad = true;
            NSLog(@"DUO_PSP_AA_BUDGET_FALLBACK: prioritize frame pacing");
        }
    }
#if DEBUG
    NSLog(@"DUO_PSP_FRAME_POLICY mode=%s state=%d game_fps=%.1f emulation_hz=%.1f clock_mhz=%.0f hot=%d", optionValues["duo_psp_frame_rate"].c_str(), (int)pspFramePolicy.state, flips / elapsed, vblanks / elapsed, (clockStatus & 0x7fffffffu) / 1e6, hot);
#endif
    resetPSPFrameWindow(now);
}

struct ScopedPSPContext {
    EAGLContext *previous = EAGLContext.currentContext;
    ScopedPSPContext() { if (pspGLContext) [EAGLContext setCurrentContext:pspGLContext]; }
    ~ScopedPSPContext() { if (pspGLContext) [EAGLContext setCurrentContext:previous]; }
};

uintptr_t pspCurrentFramebuffer() { return pspFramebuffer; }
retro_proc_address_t pspGetProcAddress(const char *name) {
    return reinterpret_cast<retro_proc_address_t>(dlsym(RTLD_DEFAULT, name));
}

void destroyPSPGraphics() {
    if (pspGLContext) {
        [EAGLContext setCurrentContext:pspGLContext];
        glDeleteFramebuffers(1, &pspFramebuffer);
        glDeleteTextures(1, &pspColor);
        glDeleteRenderbuffers(1, &pspDepth);
        [EAGLContext setCurrentContext:nil];
    }
    pspGLContext = nil;
    if (pspSurfaceTexture) CFRelease(pspSurfaceTexture);
    if (pspSurface) CFRelease(pspSurface);
    if (pspPixelPool) CFRelease(pspPixelPool);
    if (pspTextureCache) CFRelease(pspTextureCache);
    pspSurfaceTexture = nullptr;
    pspSurface = nullptr;
    pspPixelPool = nullptr;
    pspTextureCache = nullptr;
    pspFramebuffer = pspColor = pspDepth = 0;
    pspWidth = pspHeight = 0;
    pspHW = {};
    pspContextReady = false;
    pspReadback.clear();
    pspPreviousPixels.clear();
#if DEBUG
    pspNewImages = 0;
#endif
}

void preparePSPSurface() {
    if (!pspPixelPool) return;
    if (pspSurfaceTexture) CFRelease(pspSurfaceTexture);
    if (pspSurface) CFRelease(pspSurface);
    pspSurfaceTexture = nullptr;
    pspSurface = nullptr;
    // Bound ownership across the emulator, latest-frame mailbox and display.
    // If the display falls behind, render to the ordinary offscreen target;
    // never overwrite a buffer still owned by the display server.
    NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @6};
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pspPixelPool,
        (__bridge CFDictionaryRef)limit, &pspSurface) == kCVReturnWouldExceedAllocationThreshold) {
        CVOpenGLESTextureCacheFlush(pspTextureCache, 0);
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pspPixelPool,
            (__bridge CFDictionaryRef)limit, &pspSurface);
    }
    GLint texture = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
    if (pspSurface) {
        CVReturn result = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
            pspTextureCache, pspSurface, nullptr, GL_TEXTURE_2D, GL_RGBA,
            pspWidth, pspHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &pspSurfaceTexture);
        if (result != kCVReturnSuccess) {
            CFRelease(pspSurface); pspSurface = nullptr;
            CFRelease(pspPixelPool); pspPixelPool = nullptr;
            NSLog(@"DUO_PSP_SURFACE_FALLBACK: texture status=%d", result);
        }
    }
    glBindTexture(GL_TEXTURE_2D, texture);
    GLint framebuffer = 0, readFramebuffer = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, pspFramebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
        pspSurfaceTexture ? CVOpenGLESTextureGetName(pspSurfaceTexture) : pspColor, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pspColor, 0);
        if (pspSurfaceTexture) CFRelease(pspSurfaceTexture);
        if (pspSurface) CFRelease(pspSurface);
        pspSurfaceTexture = nullptr; pspSurface = nullptr;
        CFRelease(pspPixelPool); pspPixelPool = nullptr;
        NSLog(@"DUO_PSP_SURFACE_FALLBACK: framebuffer incompatible");
    }
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFramebuffer);
}

bool createPSPGraphics(retro_hw_render_callback *request) {
    if (!pspCore || !request || (request->context_type != RETRO_HW_CONTEXT_OPENGLES2 &&
        request->context_type != RETRO_HW_CONTEXT_OPENGLES3 &&
        request->context_type != RETRO_HW_CONTEXT_OPENGLES_VERSION)) return false;
    pspGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!pspGLContext || ![EAGLContext setCurrentContext:pspGLContext]) return false;
    const bool hd = optionValues["ppsspp_internal_resolution"] == "960x544";
    pspWidth = hd ? 960 : 480;
    pspHeight = hd ? 544 : 272;
    glGenFramebuffers(1, &pspFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, pspFramebuffer);
    glGenTextures(1, &pspColor);
    glBindTexture(GL_TEXTURE_2D, pspColor);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, pspWidth, pspHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pspColor, 0);
    if (request->depth || request->stencil) {
        glGenRenderbuffers(1, &pspDepth);
        glBindRenderbuffer(GL_RENDERBUFFER, pspDepth);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, pspWidth, pspHeight);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, pspDepth);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, pspDepth);
    }
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        destroyPSPGraphics();
        return false;
    }
    glViewport(0, 0, pspWidth, pspHeight);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    request->get_current_framebuffer = pspCurrentFramebuffer;
    request->get_proc_address = pspGetProcAddress;
    pspHW = *request;
    if (activeBridge.pixelBufferHandler) {
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(pspWidth), (id)kCVPixelBufferHeightKey: @(pspHeight),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
            (id)kCVPixelBufferMetalCompatibilityKey: @YES
        };
        if (CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nullptr, pspGLContext, nullptr,
                                       &pspTextureCache) == kCVReturnSuccess) {
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
                                   (__bridge CFDictionaryRef)attributes, &pspPixelPool);
        }
        NSLog(@"DUO_PSP_SURFACE: shared_buffer=%d", pspPixelPool != nullptr);
    }
    NSLog(@"DUO_PSP_GPU context=ES3 framebuffer=%ux%u", pspWidth, pspHeight);
    return true;
}

int16_t normalizedAxis(double value) {
    value = std::max(-1.0, std::min(1.0, value));
    return static_cast<int16_t>(std::lround(value * 32767.0));
}

int16_t normalizedPointer(double value) {
    value = std::max(0.0, std::min(1.0, value));
    return static_cast<int16_t>(std::lround(value * 65534.0 - 32767.0));
}

void coreLog(enum retro_log_level level, const char *format, ...) {
    // Routine PSP texture/IO logs are particularly frequent at scene changes.
    // Keep warnings and errors without doing formatting/OS logging on each load.
    if (pspCore && level < RETRO_LOG_WARN) return;
    char buffer[2048];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NSLog(@"[Azahar:%d] %s", level, buffer);
}

void rememberCoreOptions(const retro_core_options_v2 *options) {
    if (!options || !options->definitions) return;
    for (const retro_core_option_v2_definition *definition = options->definitions;
         definition->key != nullptr; ++definition) {
        if (definition->default_value) {
            optionValues.emplace(definition->key, definition->default_value);
        }
    }
    // The app owns the two-screen presentation, so request Azahar's native stacked
    // software frame and split it into the physical top and bottom bezels in Swift.
    optionValues["citra_graphics_api"] = "Software";
    optionValues["citra_layout_option"] = "default";
    optionValues["citra_resolution_factor"] = "1";
    optionValues["citra_use_cpu_jit"] = "disabled";
    optionValues["citra_use_shader_jit"] = "disabled";
}

bool environmentCallback(unsigned command, void *data) {
    switch (command) {
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
        *static_cast<unsigned *>(data) = 2;
        return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
        rememberCoreOptions(static_cast<const retro_core_options_v2 *>(data));
        return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
        auto *intl = static_cast<const retro_core_options_v2_intl *>(data);
        rememberCoreOptions(intl ? intl->us : nullptr);
        return true;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
        auto *entry = static_cast<retro_variable *>(data);
        for (; entry && entry->key; ++entry) {
            std::string value = entry->value ? entry->value : "";
            auto start = value.find("; ");
            if (start != std::string::npos) {
                value = value.substr(start + 2);
                optionValues.emplace(entry->key, value.substr(0, value.find('|')));
            }
        }
        return true;
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS: {
        auto *entry = static_cast<retro_core_option_definition *>(data);
        for (; entry && entry->key; ++entry)
            if (entry->default_value) optionValues.emplace(entry->key, entry->default_value);
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto *variable = static_cast<retro_variable *>(data);
        if (!variable || !variable->key) return false;
        auto found = optionValues.find(variable->key);
        variable->value = found == optionValues.end() ? nullptr : found->second.c_str();
        return variable->value != nullptr;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *static_cast<bool *>(data) = false;
        return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        *static_cast<const char **>(data) = systemDirectoryPath.c_str();
        return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *static_cast<const char **>(data) = saveDirectoryPath.c_str();
        return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        static_cast<retro_log_callback *>(data)->log = coreLog;
        return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        const auto requested = *static_cast<const retro_pixel_format *>(data);
        if (requested != RETRO_PIXEL_FORMAT_XRGB8888 && requested != RETRO_PIXEL_FORMAT_RGB565) return false;
        pixelFormat = requested;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        *static_cast<bool *>(data) = true;
        return true;
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        *static_cast<retro_hw_context_type *>(data) = pspCore ? RETRO_HW_CONTEXT_OPENGLES3 : RETRO_HW_CONTEXT_NONE;
        return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER:
        return createPSPGraphics(static_cast<retro_hw_render_callback *>(data));
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
        *static_cast<bool *>(data) = false;
        return true;
    case RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER:
        return false;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
        *static_cast<unsigned *>(data) = RETRO_LANGUAGE_ENGLISH;
        return true;
    case RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE:
        *static_cast<float *>(data) = 60.0f;
        return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE: {
        auto *message = static_cast<const retro_message *>(data);
        lastCoreMessage = message && message->msg ? message->msg : "Azahar error";
        if (activeBridge.messageHandler) {
            activeBridge.messageHandler([NSString stringWithUTF8String:lastCoreMessage.c_str()]);
        }
        return true;
    }
    case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
        *static_cast<unsigned *>(data) = 1; return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
        auto *message = static_cast<const retro_message_ext *>(data);
        lastCoreMessage = message && message->msg ? message->msg : "Core error";
        if (activeBridge.messageHandler) activeBridge.messageHandler([NSString stringWithUTF8String:lastCoreMessage.c_str()]);
        return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
    case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
        return true;
    case RETRO_ENVIRONMENT_SHUTDOWN:
        shutdownRequested = true;
        return true;
    default:
        return false;
    }
}

void videoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!activeBridge.videoHandler || !data) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        if (!pspGLContext || !pspContextReady || width > pspWidth || height > pspHeight) return;
        if (pspSurface && activeBridge.pixelBufferHandler) {
            // Complete writes before crossing from GL into the system display
            // renderer. No glReadPixels, row conversion, NSData or CGImage copy.
            glFinish();
            #if DEBUG
            ++pspNewImages;
            #endif
            activeBridge.pixelBufferHandler(pspSurface, pspHW.bottom_left_origin);
            return;
        }
        if (pspPixelPool) return; // Pool exhausted: keep audio/emulation moving.
        // Preserve the GPU's RGBA layout all the way to CoreGraphics. Only
        // reflect rows here; don't swizzle every pixel on the emulator queue.
#if DEBUG
        const double readbackStarted = CACurrentMediaTime();
#endif
        GLint previousFBO = 0, previousPack = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousFBO);
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &previousPack);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, pspFramebuffer);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        pspReadback.resize(width * height * 4);
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pspReadback.data());
        glBindFramebuffer(GL_READ_FRAMEBUFFER, previousFBO);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, previousPack);
#if DEBUG
        pspReadbackSeconds += CACurrentMediaTime() - readbackStarted;
#endif
        // A 30 fps game repeats frames at 60 Hz. Keep emulation/audio at full
        // speed, but don't allocate, convert or upload an identical texture.
        if (pspPreviousPixels == pspReadback) return;
        pspPreviousPixels.swap(pspReadback);
#if DEBUG
        ++pspNewImages;
        const double copyStarted = CACurrentMediaTime();
#endif
        NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
        vImage_Buffer source = {pspPreviousPixels.data(), height, width, width * 4};
        vImage_Buffer target = {pixels.mutableBytes, height, width, width * 4};
        if (pspHW.bottom_left_origin) {
            vImageVerticalReflect_ARGB8888(&source, &target, kvImageDoNotTile);
        } else {
            memcpy(pixels.mutableBytes, pspPreviousPixels.data(), width * height * 4);
        }
        bool rgba = true;
#if DEBUG
        // A/B diagnostic only; production keeps the source channel layout.
        if (pspPortableReadback) {
            const uint8_t permute[] = {2, 1, 0, 3};
            vImagePermuteChannels_ARGB8888(&target, &target, permute, kvImageDoNotTile);
            rgba = false;
        }
        pspCopySeconds += CACurrentMediaTime() - copyStarted;
#endif
        activeBridge.videoHandler(pixels, width, height, width * 4, rgba);
        return;
    }
    if (pixelFormat == RETRO_PIXEL_FORMAT_RGB565) {
        const NSUInteger convertedPitch = width * sizeof(uint32_t);
        NSMutableData *converted = [NSMutableData dataWithLength:convertedPitch * height];
        vImage_Buffer sourceBuffer = {
            const_cast<void *>(data), static_cast<vImagePixelCount>(height),
            static_cast<vImagePixelCount>(width), pitch
        };
        vImage_Buffer destinationBuffer = {
            converted.mutableBytes, static_cast<vImagePixelCount>(height),
            static_cast<vImagePixelCount>(width), convertedPitch
        };
        if (vImageConvert_RGB565toBGRA8888(255, &sourceBuffer, &destinationBuffer, kvImageNoFlags) == kvImageNoError) {
            activeBridge.videoHandler(converted, width, height, convertedPitch, NO);
        }
        return;
    }
    const NSUInteger length = pitch * height;
    activeBridge.videoHandler([NSData dataWithBytes:data length:length], width, height, pitch, NO);
}

size_t audioBatchCallback(const int16_t *data, size_t frames) {
    if (data && frames > 0)
        audioFrameBuffer.insert(audioFrameBuffer.end(), data, data + frames * 2);
    return frames;
}

void audioSampleCallback(int16_t left, int16_t right) {
    int16_t samples[] = {left, right};
    audioBatchCallback(samples, 1);
}

void inputPollCallback() {}

int16_t inputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) return 0;
    std::lock_guard<std::mutex> lock(stateMutex);
    if (device == RETRO_DEVICE_JOYPAD && id < buttonStates.size()) {
#if DEBUG
        if (buttonStates[id] && !buttonWasObserved[id]) {
            buttonWasObserved[id] = true;
            if (id == RETRO_DEVICE_ID_JOYPAD_SELECT || id == RETRO_DEVICE_ID_JOYPAD_START ||
                id == RETRO_DEVICE_ID_JOYPAD_A || id == RETRO_DEVICE_ID_JOYPAD_B ||
                id == RETRO_DEVICE_ID_JOYPAD_X || id == RETRO_DEVICE_ID_JOYPAD_Y) {
                NSLog(@"DUO_MENU_BUTTON_CORE_PASS: id=%u", id);
            }
        }
#endif
        return buttonStates[id] ? 1 : 0;
    }
    if (device == RETRO_DEVICE_ANALOG && index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
        if (id == RETRO_DEVICE_ID_ANALOG_X) return circlePad[0];
        if (id == RETRO_DEVICE_ID_ANALOG_Y) return circlePad[1];
    }
    if (device == RETRO_DEVICE_POINTER) {
        if (id == RETRO_DEVICE_ID_POINTER_X) return touchPosition[0];
        if (id == RETRO_DEVICE_ID_POINTER_Y) return touchPosition[1];
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED || id == RETRO_DEVICE_ID_POINTER_COUNT) {
#if DEBUG
            if (touchPressed && !touchWasObserved) {
                touchWasObserved = true;
                NSLog(@"DUO_TOUCH_TEST_PASS: core received touchscreen contact");
            }
#endif
            return touchPressed ? 1 : 0;
        }
    }
    return 0;
}

} // namespace

@interface AzaharCoreBridge ()
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite) double frameDuration;
@property (nonatomic, readwrite) double sampleRate;
@end

@implementation AzaharCoreBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameDuration = 1.0 / 60.0;
        _sampleRate = 32768.0;
    }
    return self;
}

- (BOOL)startWithROMURL:(NSURL *)romURL
        systemDirectory:(NSURL *)systemDirectory
          saveDirectory:(NSURL *)saveDirectory
                  error:(NSError **)error {
    [self stop];
    if (activeBridge && activeBridge != self) {
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:@"请先退出正在运行的游戏"}];
        return NO;
    }
    BOOL n64 = [@[@"z64", @"n64", @"v64"] containsObject:romURL.pathExtension.lowercaseString];
    BOOL nds = [@[@"nds", @"dsi", @"srl", @"ids"] containsObject:romURL.pathExtension.lowercaseString];
    BOOL psp = [@[@"iso", @"cso", @"chd", @"pbp", @"prx", @"pspelf"] containsObject:romURL.pathExtension.lowercaseString];
    if (!selectCore(n64, nds, psp)) {
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey:@"游戏内核未能载入"}];
        return NO;
    }
    n64SaveURL = psp ? nil : [saveDirectory URLByAppendingPathComponent:nds ? [[romURL.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@".dsv"] : [romURL.lastPathComponent stringByAppendingString:@".srm"]];
    activeBridge = self;
    systemDirectoryPath = systemDirectory.fileSystemRepresentation;
    saveDirectoryPath = saveDirectory.fileSystemRepresentation;
    optionValues.clear();
    if (n64Core) {
        optionValues["parallel-n64-alt-map"] = "enabled";
        optionValues["parallel-n64-cpucore"] = "cached_interpreter";
        optionValues["parallel-n64-gfxplugin"] = "angrylion";
        optionValues["parallel-n64-rspplugin"] = "cxd4";
        optionValues["parallel-n64-angrylion-multithread"] = "2";
    }
    if (ndsCore) {
        optionValues["melonds_screen_layout1"] = "top-bottom";
        optionValues["melonds_screen_gap"] = "0";
        optionValues["melonds_touch_mode"] = "touch";
        optionValues["melonds_boot_mode"] = "direct";
        optionValues["melonds_render_mode"] = "software";
        NSData *header = [NSData dataWithContentsOfURL:romURL options:NSDataReadingMappedIfSafe error:nil];
        bool dsiOnly = header.length > 0x12 && ((const uint8_t *)header.bytes)[0x12] == 3;
        optionValues["melonds_console_mode"] = dsiOnly ? "dsi" : "ds";
    }
    if (pspCore) {
        optionValues["ppsspp_backend"] = "opengl";
        optionValues["ppsspp_software_rendering"] = "disabled";
        optionValues["ppsspp_internal_resolution"] = "480x272";
        optionValues["ppsspp_frameskip"] = "disabled";
        optionValues["ppsspp_auto_frameskip"] = "disabled";
        optionValues["ppsspp_io_timing_method"] = "Fast";
        optionValues["ppsspp_cpu_core"] = "IR JIT";
        optionValues["ppsspp_inflight_frames"] = "No buffer";
        optionValues["ppsspp_cropto16x9"] = "disabled";
        optionValues["ppsspp_fast_memory"] = "enabled";
        optionValues["ppsspp_locked_cpu_speed"] = "disabled";
        optionValues["ppsspp_detect_vsync_swap_interval"] = "disabled";
        // The frontend ticks at ~60 Hz. Yield on every emulated vblank even
        // when a 30 fps game hasn't drawn: otherwise retro_run advances two
        // vblanks per call and doubles game/audio speed. The video callback
        // already drops unchanged pixels before conversion/UI submission.
        optionValues["ppsspp_frame_duplication"] = "enabled";
    }
    for (const auto &entry : configuredOptions) optionValues[entry.first] = entry.second;
    pspSetHighFrameRate = pspCore ? reinterpret_cast<void (*)(bool)>(dlsym(selectedCoreLibrary, "retro_duo_set_high_frame_rate")) : nullptr;
    pspDisplayCounters = pspCore ? reinterpret_cast<uint64_t (*)()>(dlsym(selectedCoreLibrary, "retro_duo_display_counters")) : nullptr;
    pspClockStatus = pspCore ? reinterpret_cast<unsigned (*)()>(dlsym(selectedCoreLibrary, "retro_duo_clock_status")) : nullptr;
    pspDisableAntialias = pspCore ? reinterpret_cast<void (*)()>(dlsym(selectedCoreLibrary, "retro_duo_disable_antialias")) : nullptr;
    pspAAWindows = pspAABusyWindows = 0;
#if DEBUG
    pspPortableReadback = [NSProcessInfo.processInfo.arguments containsObject:@"-psp-portable-readback"];
    pspReadbackSeconds = pspCopySeconds = 0;
#endif
    pspAADisabledForLoad = optionValues["duo_psp_antialias"] != "enabled";
    pspFramePolicy.reset(optionValues["duo_psp_frame_rate"] == "high");
    pspPolicyWindowStart = pspPolicyLastFrame = 0;
    if (pspSetHighFrameRate) pspSetHighFrameRate(false);
    lastCoreMessage.clear();
    pixelFormat = RETRO_PIXEL_FORMAT_XRGB8888;
    {
        std::lock_guard<std::mutex> lock(stateMutex);
        buttonStates.fill(false);
        circlePad.fill(0);
        touchPosition.fill(0);
        touchPressed = false;
#if DEBUG
        touchWasObserved = false;
        buttonWasObserved.fill(false);
#endif
        shutdownRequested = false;
    }

    api.retro_set_environment(environmentCallback);
    api.retro_set_video_refresh(videoCallback);
    api.retro_set_audio_sample(audioSampleCallback);
    api.retro_set_audio_sample_batch(audioBatchCallback);
    api.retro_set_input_poll(inputPollCallback);
    api.retro_set_input_state(inputStateCallback);
    api.retro_init();

    std::string path = romURL.fileSystemRepresentation;
    retro_game_info gameInfo{};
    gameInfo.path = path.c_str();
    NSData *romData = ndsCore ? [NSData dataWithContentsOfURL:romURL options:NSDataReadingMappedIfSafe error:nil] : nil;
    if (ndsCore) { gameInfo.data = romData.bytes; gameInfo.size = romData.length; }
    if (!api.retro_load_game(&gameInfo)) {
        api.retro_deinit();
        destroyPSPGraphics();
        activeBridge = nil;
        unloadSelectedCoreLibrary();
        n64Core = false;
        ndsCore = false;
        pspCore = false;
        NSString *description = lastCoreMessage.empty()
            ? @"内核无法载入游戏。请检查文件是否完整，以及所需系统文件是否已配置。"
            : [NSString stringWithUTF8String:lastCoreMessage.c_str()];
        if (error) {
            *error = [NSError errorWithDomain:AzaharBridgeErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }

    if (pspGLContext && pspHW.context_reset) {
        pspHW.context_reset();
        pspContextReady = true;
        [EAGLContext setCurrentContext:nil];
    }
    retro_system_av_info avInfo{};
    api.retro_get_system_av_info(&avInfo);
    self.frameDuration = avInfo.timing.fps > 0 ? 1.0 / avInfo.timing.fps : 1.0 / 60.0;
    self.sampleRate = avInfo.timing.sample_rate > 0 ? avInfo.timing.sample_rate : 32768.0;
    if (n64Core || ndsCore) {
        NSData *save = [NSData dataWithContentsOfURL:n64SaveURL];
        void *memory = api.retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
        size_t size = api.retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
        if (memory && save.length == size) memcpy(memory, save.bytes, size);
    }
    self.running = YES;
    return YES;
}

- (void)runFrame {
    @autoreleasepool {
    if (self.running && !shutdownRequested) {
        // DeSmuME emits only a few samples from each emulated scanline. Sending
        // every fragment across the Swift bridge creates thousands of tiny
        // player buffers and audible seams, so submit one native PCM block per
        // emulation frame instead.
        audioFrameBuffer.clear();
        const double started = pspCore ? CACurrentMediaTime() : 0;
        if (pspGLContext) [EAGLContext setCurrentContext:pspGLContext];
        if (pspGLContext) preparePSPSurface();
        api.retro_run();
        if (pspGLContext) [EAGLContext setCurrentContext:nil];
        if (pspCore) updatePSPFramePolicy(started, CACurrentMediaTime(), self.frameDuration);
#if DEBUG
        if (pspCore) {
            static double windowStart = 0, total = 0, longest = 0;
            static unsigned frames = 0, overBudget = 0;
            const double now = CACurrentMediaTime(), elapsed = now - started;
            if (windowStart == 0) windowStart = started;
            total += elapsed; longest = std::max(longest, elapsed); ++frames;
            if (elapsed > self.frameDuration) ++overBudget;
            if (now - windowStart >= 2) {
                task_vm_info_data_t info{};
                mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
                task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
                NSLog(@"DUO_PSP_PERF render=%ux%u work_avg_ms=%.2f work_max_ms=%.2f over_budget=%u/%u presentations_per_sec=%.1f footprint_mb=%.0f", pspWidth, pspHeight, 1000 * total / frames, 1000 * longest, overBudget, frames, pspNewImages / (now - windowStart), info.phys_footprint / 1048576.0);
                NSLog(@"DUO_PSP_TRANSFER read_ms=%.3f copy_ms=%.3f", 1000 * pspReadbackSeconds / frames, 1000 * pspCopySeconds / frames);
                pspReadbackSeconds = pspCopySeconds = 0;
                windowStart = now; total = longest = 0; frames = overBudget = pspNewImages = 0;
            }
        }
#endif
        if (self.audioHandler && !audioFrameBuffer.empty()) {
            NSData *samples = [NSData dataWithBytes:audioFrameBuffer.data()
                                            length:audioFrameBuffer.size() * sizeof(int16_t)];
            self.audioHandler(samples, self.sampleRate);
        }
    }
    if (shutdownRequested && self.exitHandler) {
        void (^handler)(void) = self.exitHandler;
        self.exitHandler = nil;
        handler();
    }
    }
}

- (void)stop {
    if (!self.running) return;
    [self savePersistentData];
    if (pspGLContext) [EAGLContext setCurrentContext:pspGLContext];
    api.retro_unload_game();
    api.retro_deinit();
    destroyPSPGraphics();
    self.running = NO;
    if (activeBridge == self) activeBridge = nil;
    // These libretro cores keep process-wide device objects. In particular,
    // DeSmuME destroys its Slot-1 instances during retro_deinit but its older
    // one-time initializer leaves dangling pointers behind. Unloading the
    // dynamically loaded core resets that state before the next cartridge.
    pspSetHighFrameRate = nullptr;
    pspDisplayCounters = nullptr;
    pspClockStatus = nullptr;
    pspDisableAntialias = nullptr;
    unloadSelectedCoreLibrary();
    n64Core = false;
    ndsCore = false;
    pspCore = false;
}

- (void)savePersistentData {
    if (!self.running || (!n64Core && !ndsCore)) return;
    void *memory = api.retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = api.retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (memory && size) {
        NSError *error;
        if (![[NSData dataWithBytes:memory length:size] writeToURL:n64SaveURL options:NSDataWritingAtomic error:&error]) {
            if (self.messageHandler) self.messageHandler(error.localizedDescription);
        }
    }
}

- (NSData *)serializeStateWithError:(NSError **)error {
    ScopedPSPContext context;
    if (!self.running) return nil;
    size_t size = api.retro_serialize_size();
    if (size == 0 || size > 512 * 1024 * 1024) {
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:20 userInfo:@{NSLocalizedDescriptionKey:@"当前内核不支持即时存档"}];
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!api.retro_serialize(data.mutableBytes, size)) {
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:21 userInfo:@{NSLocalizedDescriptionKey:@"即时存档写入失败"}];
        return nil;
    }
    return data;
}

- (BOOL)loadStateData:(NSData *)data error:(NSError **)error {
    ScopedPSPContext context;
    if (!self.running || data.length == 0 || !api.retro_unserialize(data.bytes, data.length)) {
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:22 userInfo:@{NSLocalizedDescriptionKey:@"即时存档与当前游戏或内核不兼容"}];
        return NO;
    }
    return YES;
}

- (void)setCheatAtIndex:(NSUInteger)index enabled:(BOOL)enabled code:(NSString *)code {
    if (self.running) api.retro_cheat_set((unsigned)index, enabled, code.UTF8String);
}

- (void)resetCheats { if (self.running) api.retro_cheat_reset(); }

- (void)setCoreOptionValue:(NSString *)value forKey:(NSString *)key {
    configuredOptions[key.UTF8String] = value.UTF8String;
}

+ (NSDictionary<NSString *, NSString *> *)installPackageURL:(NSURL *)url
                                            saveDirectory:(NSURL *)directory error:(NSError **)error {
    if (activeBridge) {
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:@"请先退出游戏再安装 CIA"}];
        return nil;
    }
    selectCore(false);
    optionValues.clear();
    saveDirectoryPath = directory.fileSystemRepresentation;
    systemDirectoryPath = saveDirectoryPath;
    retro_set_environment(environmentCallback);
    retro_init();
    char installed[4096] = {};
    uint64_t title = 0;
    int status = duo_install_cia(url.fileSystemRepresentation, installed, sizeof(installed), &title);
    retro_deinit();
    if (status != 0) {
        NSString *message = status == 5 ? @"CIA 内容已加密，请导入由自己主机导出的解密版本" :
            status == 6 ? @"这是系统标题或 DSiWare CIA，请使用相应的系统文件安装流程" : @"CIA/ZCIA 安装失败：文件不完整、格式错误或写入失败";
        if (error) *error = [NSError errorWithDomain:AzaharBridgeErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey:message}];
        return nil;
    }
    return @{@"path": [NSString stringWithUTF8String:installed], @"titleID": [NSString stringWithFormat:@"%016llx", (unsigned long long)title]};
}

- (void)setButton:(AzaharButton)button pressed:(BOOL)pressed {
    std::lock_guard<std::mutex> lock(stateMutex);
    if (button >= 0 && static_cast<size_t>(button) < buttonStates.size()) {
        buttonStates[button] = pressed;
    }
}

- (void)setCirclePadX:(double)x y:(double)y {
    std::lock_guard<std::mutex> lock(stateMutex);
    circlePad[0] = normalizedAxis(x);
    circlePad[1] = normalizedAxis(y);
}

- (void)setTouchX:(double)x y:(double)y pressed:(BOOL)pressed {
    std::lock_guard<std::mutex> lock(stateMutex);
    const double clampedX = std::max(0.0, std::min(1.0, x));
    const double clampedY = std::max(0.0, std::min(1.0, y));
    if (ndsCore) {
        // melonDS receives pointer coordinates for its complete 256x384
        // top-bottom framebuffer. The touch panel is the lower 256x192 half.
        touchPosition[0] = normalizedPointer((0.5 + clampedX * 255.0) / 256.0);
        touchPosition[1] = normalizedPointer((192.5 + clampedY * 191.0) / 384.0);
    } else {
        // Azahar receives pointer coordinates for its complete 400x480
        // framebuffer. The lower touch panel is 320x240 and centered.
        touchPosition[0] = normalizedPointer((40.5 + clampedX * 319.0) / 400.0);
        touchPosition[1] = normalizedPointer((240.5 + clampedY * 239.0) / 480.0);
    }
    touchPressed = pressed;
}

@end
