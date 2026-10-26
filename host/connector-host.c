/*
 * connector-host: streams one X11 output (a virtual monitor) to the iPad app
 * over the USB cable (usbmuxd), Wi-Fi or the internet, and injects the iPad's
 * touch input back as mouse events.
 *
 *   capture  : XShm grab of the output's rectangle on the root window,
 *              cursor composited from XFixes; unchanged frames are skipped
 *   encode   : H.264 via NVENC (BGR0 input, no CPU colour conversion),
 *              else VA-API (Intel/AMD; NV12 converted on the CPU, then
 *              uploaded), else libx264
 *   transport: usbmuxd -> TCP port CONNECTOR_PORT on the iPad, or the iPad
 *              connects to our CONNECTOR_PORT (TLS-PSK, key paired over USB);
 *              the cable wins when both are available
 *   input    : XTest; text is typed through the current keyboard layout, or a
 *              spare keycode remapped on the fly for characters it lacks
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/sockios.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/XTest.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <xkbcommon/xkbcommon.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>

#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>

#include <usbmuxd.h>

#include "protocol.h"

#ifndef CONNECTOR_VERSION
#define CONNECTOR_VERSION "dev"
#endif

/* ---------------------------------------------------------------- options */

static struct {
    const char *output;
    const char *encoder;
    int fps;
    int bitrate_mbps;
    int lan_mbps;
    int internet_mbps;
    int quality;
    int port;
    int listen_port;
    int network;
    int usb;
    const char *address;
    int verbose;
    int manage_display;
    char root[4096]; /* the project directory (host/..) */
    char display_script[4160];
    double grace;
} opt = {
    .output = "HDMI-1-2",
    .encoder = "auto",
    .fps = 60,
    .bitrate_mbps = 80,
    .lan_mbps = 30,
    .internet_mbps = 10,
    .quality = 16,
    .port = CONNECTOR_PORT,
    .listen_port = CONNECTOR_PORT,
    .network = 1,
    .usb = 1,
    .grace = 10,
};

/* cq per quality level chosen on the iPad: normal / high / maximum */
static const int quality_cq[3] = {22, 16, 12};

static volatile sig_atomic_t quit_requested;

static void on_signal(int sig) { (void)sig; quit_requested = 1; }

static void logmsg(const char *fmt, ...)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    fprintf(stderr, "[%02d:%02d:%02d] ", tm.tm_hour, tm.tm_min, tm.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------------------------------------------------------------- X11 */

typedef struct {
    int x, y, w, h;
} Rect;

typedef struct {
    Display *dpy;
    Window root;
    int randr_event_base;
    int xfixes_event_base;
    int geometry_dirty;
    int cursor_dirty;

    char output[64]; /* what we capture: opt.output, or the main screen when mirroring */
    Rect area;       /* output rectangle on the root window; w == 0 if inactive */
    XImage *img;
    XShmSegmentInfo shm;

    uint32_t *cursor; /* ARGB premultiplied */
    int cursor_w, cursor_h, cursor_xhot, cursor_yhot;
} X11;

static int find_output(X11 *x, Rect *out)
{
    memset(out, 0, sizeof(*out));
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(x->dpy, x->root);
    if (!res)
        return 0;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(x->dpy, res, res->outputs[i]);
        if (!oi)
            continue;
        if (strcmp(oi->name, x->output) == 0 && oi->crtc) {
            XRRCrtcInfo *ci = XRRGetCrtcInfo(x->dpy, res, oi->crtc);
            if (ci && ci->width && ci->height) {
                int rotated = ci->rotation & (RR_Rotate_90 | RR_Rotate_270);
                out->x = ci->x;
                out->y = ci->y;
                out->w = rotated ? ci->height : ci->width;
                out->h = rotated ? ci->width : ci->height;
            }
            if (ci)
                XRRFreeCrtcInfo(ci);
        }
        XRRFreeOutputInfo(oi);
    }
    XRRFreeScreenResources(res);
    return out->w > 0;
}

/* The computer's own screen: the primary output, else any other active one. */
static int main_output(X11 *x, char *name, size_t n)
{
    name[0] = 0;
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(x->dpy, x->root);
    if (!res)
        return 0;
    RROutput primary = XRRGetOutputPrimary(x->dpy, x->root);
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(x->dpy, res, res->outputs[i]);
        if (!oi)
            continue;
        if (oi->crtc && strcmp(oi->name, opt.output) != 0 && (res->outputs[i] == primary || !name[0]))
            snprintf(name, n, "%s", oi->name);
        XRRFreeOutputInfo(oi);
    }
    XRRFreeScreenResources(res);
    return name[0] != 0;
}

static void list_outputs(X11 *x)
{
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(x->dpy, x->root);
    for (int i = 0; res && i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(x->dpy, res, res->outputs[i]);
        if (!oi)
            continue;
        printf("%-12s %s", oi->name,
               oi->connection == RR_Connected ? "connected" : "disconnected");
        if (oi->crtc) {
            XRRCrtcInfo *ci = XRRGetCrtcInfo(x->dpy, res, oi->crtc);
            if (ci)
                printf("  %ux%u+%d+%d", ci->width, ci->height, ci->x, ci->y);
            XRRFreeCrtcInfo(ci);
        }
        printf("\n");
        XRRFreeOutputInfo(oi);
    }
    if (res)
        XRRFreeScreenResources(res);
}

static void capture_free(X11 *x)
{
    if (!x->img)
        return;
    XShmDetach(x->dpy, &x->shm);
    XSync(x->dpy, False);
    x->img->data = NULL;
    XDestroyImage(x->img);
    shmdt(x->shm.shmaddr);
    x->img = NULL;
}

static int capture_init(X11 *x)
{
    capture_free(x);
    int scr = DefaultScreen(x->dpy);
    x->img = XShmCreateImage(x->dpy, DefaultVisual(x->dpy, scr), DefaultDepth(x->dpy, scr),
                             ZPixmap, NULL, &x->shm, x->area.w, x->area.h);
    if (!x->img || x->img->bits_per_pixel != 32) {
        logmsg("XShmCreateImage failed (need a 24/32-bit TrueColor screen)");
        return 0;
    }
    x->shm.shmid = shmget(IPC_PRIVATE, (size_t)x->img->bytes_per_line * x->img->height,
                          IPC_CREAT | 0600);
    if (x->shm.shmid < 0) {
        perror("shmget");
        return 0;
    }
    x->shm.shmaddr = x->img->data = shmat(x->shm.shmid, NULL, 0);
    x->shm.readOnly = False;
    XShmAttach(x->dpy, &x->shm);
    XSync(x->dpy, False);
    shmctl(x->shm.shmid, IPC_RMID, NULL);
    return 1;
}

static void cursor_update(X11 *x)
{
    XFixesCursorImage *ci = XFixesGetCursorImage(x->dpy);
    x->cursor_dirty = 0;
    if (!ci)
        return;
    free(x->cursor);
    x->cursor_w = ci->width;
    x->cursor_h = ci->height;
    x->cursor_xhot = ci->xhot;
    x->cursor_yhot = ci->yhot;
    x->cursor = malloc(sizeof(uint32_t) * ci->width * ci->height);
    /* XFixes hands out pixels as unsigned long (64-bit on amd64). */
    for (int i = 0; i < ci->width * ci->height; i++)
        x->cursor[i] = (uint32_t)ci->pixels[i];
    XFree(ci);
}

/* Composites the cursor into the captured image. Returns 1 if it is visible. */
static int cursor_draw(X11 *x, int px, int py)
{
    if (!x->cursor)
        return 0;
    int cx = px - x->area.x - x->cursor_xhot;
    int cy = py - x->area.y - x->cursor_yhot;
    if (cx >= x->area.w || cy >= x->area.h || cx + x->cursor_w <= 0 || cy + x->cursor_h <= 0)
        return 0;
    for (int j = 0; j < x->cursor_h; j++) {
        int dy = cy + j;
        if (dy < 0 || dy >= x->area.h)
            continue;
        uint32_t *dst = (uint32_t *)(x->img->data + (size_t)dy * x->img->bytes_per_line);
        const uint32_t *src = x->cursor + j * x->cursor_w;
        for (int i = 0; i < x->cursor_w; i++) {
            int dx = cx + i;
            if (dx < 0 || dx >= x->area.w)
                continue;
            uint32_t s = src[i], a = s >> 24;
            if (!a)
                continue;
            uint32_t d = dst[dx], ia = 255 - a;
            uint32_t r = ((s >> 16) & 255) + ((d >> 16) & 255) * ia / 255;
            uint32_t g = ((s >> 8) & 255) + ((d >> 8) & 255) * ia / 255;
            uint32_t b = (s & 255) + (d & 255) * ia / 255;
            dst[dx] = (r << 16) | (g << 8) | b;
        }
    }
    return 1;
}

static void x11_drain_events(X11 *x)
{
    while (XPending(x->dpy)) {
        XEvent ev;
        XNextEvent(x->dpy, &ev);
        XRRUpdateConfiguration(&ev);
        if (ev.type == x->xfixes_event_base + XFixesCursorNotify)
            x->cursor_dirty = 1;
        else if (ev.type == x->randr_event_base + RRScreenChangeNotify ||
                 ev.type == x->randr_event_base + RRNotify)
            x->geometry_dirty = 1;
    }
}

/* ---------------------------------------------------------------- encoder */

typedef struct {
    AVCodecContext *ctx;
    AVFrame *frame; /* BGR0 wrapper (NVENC) or the converted YUV frame */
    AVPacket *pkt;
    struct SwsContext *sws;
    AVBufferRef *hw_device, *hw_frames; /* VA-API */
    int64_t pts;
    int mbps;      /* peak bitrate, depends on how the iPad is connected */
    double rate;   /* peak bitrate in use, Mbit/s: below mbps while the network can't keep up */
    int live_rate; /* takes a new peak bitrate without reopening (NVENC, x264) */
} Encoder;

static void encoder_close(Encoder *e)
{
    avcodec_free_context(&e->ctx);
    av_frame_free(&e->frame);
    av_packet_free(&e->pkt);
    sws_freeContext(e->sws);
    e->sws = NULL;
    av_buffer_unref(&e->hw_frames);
    av_buffer_unref(&e->hw_device);
}

/* Peak bitrate with room for about four frames; the average stays well below. */
static void encoder_rc(AVCodecContext *c, double mbps)
{
    c->rc_max_rate = (int64_t)(mbps * 1e6);
    c->bit_rate = c->rc_max_rate / 2;
    c->rc_buffer_size = (int)(c->rc_max_rate / opt.fps * 4);
}

/* Settings shared by all encoders: no B-frames, long GOP (keyframes on demand),
 * BT.709 limited range like the iPad expects. */
static AVCodecContext *encoder_context(const AVCodec *codec, Encoder *e, int w, int h, enum AVPixelFormat fmt)
{
    AVCodecContext *c = avcodec_alloc_context3(codec);
    c->width = w;
    c->height = h;
    c->time_base = (AVRational){1, opt.fps};
    c->framerate = (AVRational){opt.fps, 1};
    c->gop_size = opt.fps * 10;
    c->max_b_frames = 0;
    c->pix_fmt = fmt;
    encoder_rc(c, e->rate);
    c->flags |= AV_CODEC_FLAG_LOW_DELAY;
    c->color_range = AVCOL_RANGE_MPEG;
    c->colorspace = AVCOL_SPC_BT709;
    c->color_primaries = AVCOL_PRI_BT709;
    c->color_trc = AVCOL_TRC_BT709;
    return c;
}

/* VA-API: tries each GPU render node and the encoder variants drivers offer.
 * Returns an opened context or NULL. */
static AVCodecContext *vaapi_open(const AVCodec *codec, Encoder *e, int w, int h)
{
    /* QVBR/VBR cap the bitrate; many drivers only do constant QP (the
     * network path still skips frames when the link is full). */
    static const char *const rc_modes[] = {"QVBR", "VBR", "CQP"};
    for (int node = 128; node < 136; node++) {
        char dev[32];
        snprintf(dev, sizeof(dev), "/dev/dri/renderD%d", node);
        if (access(dev, R_OK | W_OK) != 0)
            continue;
        av_log_set_level(AV_LOG_QUIET); /* probing prints errors for every miss */
        AVBufferRef *device = NULL;
        if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VAAPI, dev, NULL, 0) < 0) {
            av_log_set_level(AV_LOG_ERROR);
            continue;
        }
        AVBufferRef *frames = av_hwframe_ctx_alloc(device);
        AVHWFramesContext *fc = (AVHWFramesContext *)frames->data;
        fc->format = AV_PIX_FMT_VAAPI;
        fc->sw_format = AV_PIX_FMT_NV12;
        fc->width = w;
        fc->height = h;
        fc->initial_pool_size = 8;
        if (av_hwframe_ctx_init(frames) == 0) {
            /* newer Intel chips only have the low-power encoder */
            for (int lp = 0; lp < 2; lp++) {
                for (int m = 0; m < 3; m++) {
                    AVCodecContext *c = encoder_context(codec, e, w, h, AV_PIX_FMT_VAAPI);
                    c->hw_frames_ctx = av_buffer_ref(frames);
                    av_opt_set(c->priv_data, "low_power", lp ? "1" : "0", 0);
                    av_opt_set(c->priv_data, "async_depth", "1", 0);
                    av_opt_set(c->priv_data, "rc_mode", rc_modes[m], 0);
                    av_opt_set(c->priv_data, "profile", "high", 0);
                    c->global_quality = opt.quality;
                    av_opt_set_int(c->priv_data, "qp", opt.quality, 0);
                    if (avcodec_open2(c, codec, NULL) == 0) {
                        av_log_set_level(AV_LOG_ERROR);
                        e->hw_device = device;
                        e->hw_frames = frames;
                        logmsg("VA-API on %s: %s%s rate control", dev, rc_modes[m], lp ? ", low-power" : "");
                        return c;
                    }
                    avcodec_free_context(&c);
                }
            }
        }
        av_buffer_unref(&frames);
        av_buffer_unref(&device);
        av_log_set_level(AV_LOG_ERROR);
    }
    return NULL;
}

static int encoder_try(Encoder *e, const char *name, int w, int h)
{
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    if (!codec)
        return 0;
    int nvenc = strstr(name, "nvenc") != NULL, vaapi = strstr(name, "vaapi") != NULL;
    AVCodecContext *c;
    char q[16];
    snprintf(q, sizeof(q), "%d", opt.quality);
    if (vaapi) {
        if (!(c = vaapi_open(codec, e, w, h)))
            return 0;
    } else {
        c = encoder_context(codec, e, w, h, nvenc ? AV_PIX_FMT_BGR0 : AV_PIX_FMT_YUV420P);
        if (nvenc) {
            av_opt_set(c->priv_data, "preset", "p1", 0);
            av_opt_set(c->priv_data, "tune", "ull", 0);
            av_opt_set(c->priv_data, "profile", "high", 0);
            av_opt_set(c->priv_data, "rc", "vbr", 0);
            av_opt_set(c->priv_data, "cq", q, 0);
            av_opt_set(c->priv_data, "zerolatency", "1", 0);
            av_opt_set(c->priv_data, "delay", "0", 0);
            av_opt_set(c->priv_data, "forced-idr", "1", 0);
        } else {
            av_opt_set(c->priv_data, "preset", "ultrafast", 0);
            av_opt_set(c->priv_data, "tune", "zerolatency", 0);
            av_opt_set(c->priv_data, "crf", q, 0);
            av_opt_set(c->priv_data, "forced-idr", "1", 0);
        }
        if (avcodec_open2(c, codec, NULL) < 0) {
            avcodec_free_context(&c);
            return 0;
        }
    }
    e->ctx = c;
    e->live_rate = nvenc || strcmp(name, "libx264") == 0;
    e->pkt = av_packet_alloc();
    e->frame = av_frame_alloc();
    e->frame->format = nvenc ? AV_PIX_FMT_BGR0 : vaapi ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P;
    e->frame->width = w;
    e->frame->height = h;
    e->frame->color_range = c->color_range;
    e->frame->colorspace = c->colorspace;
    if (!nvenc) {
        av_frame_get_buffer(e->frame, 0);
        e->sws = sws_getContext(w, h, AV_PIX_FMT_BGR0, w, h, e->frame->format, SWS_POINT, NULL, NULL, NULL);
        /* full-range RGB in, limited-range BT.709 out (matches the stream's VUI) */
        sws_setColorspaceDetails(e->sws, sws_getCoefficients(SWS_CS_DEFAULT), 1,
                                 sws_getCoefficients(SWS_CS_ITU709), 0, 0, 1 << 16, 1 << 16);
    }
    logmsg("encoder: %s %dx%d @%d fps, max %g Mbit/s", name, w, h, opt.fps, e->rate);
    return 1;
}

static int encoder_open(Encoder *e, int w, int h)
{
    encoder_close(e);
    e->pts = 0;
    if (strcmp(opt.encoder, "auto") == 0)
        return encoder_try(e, "h264_nvenc", w, h) || encoder_try(e, "h264_vaapi", w, h) ||
               encoder_try(e, "libx264", w, h);
    if (strcmp(opt.encoder, "nvenc") == 0)
        return encoder_try(e, "h264_nvenc", w, h);
    if (strcmp(opt.encoder, "vaapi") == 0)
        return encoder_try(e, "h264_vaapi", w, h);
    if (strcmp(opt.encoder, "x264") == 0)
        return encoder_try(e, "libx264", w, h);
    return encoder_try(e, opt.encoder, w, h);
}

/* Changes the peak bitrate from the next frame on (encoders with live_rate).
 * NVENC answers with a keyframe: FFmpeg resets it for every change. */
static void encoder_set_rate(Encoder *e, double mbps)
{
    e->rate = mbps;
    if (e->ctx)
        encoder_rc(e->ctx, mbps);
}

/* Encodes one captured BGR0 frame; packets are then read from e->ctx. */
static int encoder_send(Encoder *e, uint8_t *bgr0, int stride, int h, int idr)
{
    AVFrame *f = e->frame;
    if (e->sws) {
        const uint8_t *src[1] = {bgr0};
        av_frame_make_writable(f);
        sws_scale(e->sws, src, &stride, 0, h, f->data, f->linesize);
    } else {
        f->data[0] = bgr0;
        f->linesize[0] = stride;
    }
    f->pts = e->pts++;
    f->pict_type = idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    int rc;
    if (e->hw_frames) {
        AVFrame *hw = av_frame_alloc();
        rc = av_hwframe_get_buffer(e->hw_frames, hw, 0);
        if (rc == 0)
            rc = av_hwframe_transfer_data(hw, f, 0);
        if (rc == 0) {
            av_frame_copy_props(hw, f);
            rc = avcodec_send_frame(e->ctx, hw);
        }
        av_frame_free(&hw);
    } else {
        rc = avcodec_send_frame(e->ctx, f);
    }
    if (!e->sws)
        f->data[0] = NULL;
    return rc == 0;
}

/* ---------------------------------------------------------------- transport */

static void scratch_reset(Display *dpy);

#define SEND_TIMEOUT_SEC 5
#define HANDSHAKE_TIMEOUT_SEC 4

enum { LINK_USB, LINK_LAN, LINK_INTERNET };
static const char *const link_names[] = {"USB", "Wi-Fi", "internet"};

typedef struct {
    int fd;   /* -1 if the iPad is not connected */
    SSL *ssl; /* network links only */
    int kind;
} Link;

/* Waits for the socket to become ready; 0 on timeout. */
static int wait_fd(int fd, short events, double deadline)
{
    for (;;) {
        int ms = (int)((deadline - now_sec()) * 1000);
        if (ms <= 0)
            return 0;
        struct pollfd p = {fd, events, 0};
        int r = poll(&p, 1, ms);
        if (r > 0)
            return 1;
        if (r == 0 || errno != EINTR)
            return 0;
    }
}

static int send_all(Link *l, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    double deadline = now_sec() + SEND_TIMEOUT_SEC;
    while (len) {
        if (l->ssl) {
            int n = SSL_write(l->ssl, p, len > (1u << 20) ? (1 << 20) : (int)len);
            if (n > 0) {
                p += n;
                len -= n;
                continue;
            }
            int e = SSL_get_error(l->ssl, n);
            int want = e == SSL_ERROR_WANT_WRITE ? POLLOUT : e == SSL_ERROR_WANT_READ ? POLLIN : 0;
            if (want && wait_fd(l->fd, want, deadline))
                continue;
            if (want)
                logmsg("send: iPad stopped reading for %d s", SEND_TIMEOUT_SEC);
            else
                logmsg("send: TLS error %d (%s)", e, strerror(errno));
            ERR_clear_error();
            return 0;
        }
        ssize_t n = send(l->fd, p, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                logmsg("send: iPad stopped reading for %d s", SEND_TIMEOUT_SEC);
            else
                logmsg("send: %s", strerror(errno));
            return 0;
        }
        p += n;
        len -= n;
    }
    return 1;
}

/* Returns the number of bytes read, 0 if nothing is available, -1 if the connection is gone. */
static ssize_t link_recv(Link *l, void *buf, size_t cap)
{
    if (l->ssl) {
        int n = SSL_read(l->ssl, buf, (int)cap);
        if (n > 0)
            return n;
        int e = SSL_get_error(l->ssl, n);
        if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
            return 0;
        if (e == SSL_ERROR_ZERO_RETURN || (e == SSL_ERROR_SYSCALL && errno == 0))
            logmsg("recv: the app closed the connection");
        else
            logmsg("recv: TLS error %d (%s)", e, strerror(errno));
        ERR_clear_error();
        return -1;
    }
    ssize_t n = recv(l->fd, buf, cap, MSG_DONTWAIT);
    if (n == 0) {
        logmsg("recv: the app closed the connection");
        return -1;
    }
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            return 0;
        logmsg("recv: %s", strerror(errno));
        return -1;
    }
    return n;
}

static void link_close(Display *dpy, Link *l)
{
    if (l->ssl)
        SSL_free(l->ssl);
    if (l->fd >= 0)
        close(l->fd);
    l->ssl = NULL;
    l->fd = -1;
    /* Release any button the iPad was holding down. */
    for (unsigned b = 1; b <= 3; b++)
        XTestFakeButtonEvent(dpy, b, False, CurrentTime);
    XFlush(dpy);
    scratch_reset(dpy);
}

/* Bytes sent but not yet acknowledged by the iPad. */
static int link_backlog(Link *l)
{
    int n = 0;
    return ioctl(l->fd, SIOCOUTQ, &n) == 0 ? n : 0;
}

static int send_msg(Link *l, int type, const void *payload, uint32_t len)
{
    uint8_t hdr[CONNECTOR_HDR_LEN] = {type, len >> 24, len >> 16, len >> 8, len};
    return send_all(l, hdr, sizeof(hdr)) && (len == 0 || send_all(l, payload, len));
}

static int send_config(Link *l, int w, int h)
{
    uint8_t p[8] = {w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h};
    return send_msg(l, MSG_CONFIG, p, sizeof(p));
}

/* Returns a connected socket to the app on the first USB-attached iOS device, or -1. */
static int device_connect(void)
{
    usbmuxd_device_info_t *list = NULL;
    int n = usbmuxd_get_device_list(&list);
    int fd = -1;
    for (int i = 0; i < n && fd < 0; i++) {
        if (list[i].conn_type != CONNECTION_TYPE_USB)
            continue;
        fd = usbmuxd_connect(list[i].handle, (unsigned short)opt.port);
        if (fd >= 0) {
            /* libusbmuxd hands the socket out non-blocking; a full send buffer
             * (big keyframe) must make us wait, not drop the connection. */
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
            struct timeval tv = {SEND_TIMEOUT_SEC, 0};
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            int sndbuf = 4 << 20;
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
            logmsg("connected over USB to %s", list[i].udid);
        }
    }
    if (list)
        usbmuxd_device_list_free(&list);
    return fd;
}

/* ---------------------------------------------------------------- rate control */

/* Over the network the peak bitrate follows what the link delivers: while
 * many frames have to be skipped it steps down, and after a calm while with
 * the video using the cap it steps up again; a step up the link can't take
 * makes the next try wait twice as long. Each change costs a keyframe on
 * NVENC, so changes are few and large. The cap is not the output: NVENC
 * averages a quarter to a half of it. */
#define RATE_MIN_MBPS 1.0
#define RATE_HOLD_SEC 5.0

typedef struct {
    double t0;         /* start of the measuring window */
    int backlog0;      /* unacknowledged bytes at t0 */
    long sent, video;  /* bytes handed to the socket / encoded in this window */
    int skipped;       /* frames skipped in this window */
    double changed_at; /* last change of the rate (or the start of the link) */
    double calm_since; /* no frames skipped since */
    double hold;       /* calm time needed before trying a higher rate */
    int probing;       /* the last change was an increase */
} RateCtl;

static void rate_start(RateCtl *r, double now)
{
    *r = (RateCtl){.t0 = now, .changed_at = now, .calm_since = now, .hold = RATE_HOLD_SEC};
}

static double rate_round(double mbps)
{
    mbps = (int)(mbps * 2 + 0.5) / 2.0;
    return mbps < RATE_MIN_MBPS ? RATE_MIN_MBPS : mbps;
}

/* Runs about once a second; returns a new peak bitrate, or 0 to keep it. */
static double rate_update(RateCtl *r, Link *l, const Encoder *e, double now)
{
    double dt = now - r->t0;
    if (dt < 1.0)
        return 0;
    int backlog = link_backlog(l);
    double acked = (r->sent - (backlog - r->backlog0)) * 8 / dt / 1e6;
    double video = r->video * 8 / dt / 1e6;
    int skipped = r->skipped;
    if (opt.verbose > 1)
        logmsg("rate: %.1f s, acked %.1f, video %.1f of %g Mbit/s, %d skipped", dt, acked, video, e->rate, skipped);
    r->t0 = now;
    r->backlog0 = backlog;
    r->sent = r->video = r->skipped = 0;

    if (skipped) {
        r->calm_since = now;
        /* A burst of big frames (a scene change) skips a few, a link that
         * can't keep up skips many. */
        if (skipped < opt.fps / 4 || now - r->changed_at < 2.0 || e->rate <= RATE_MIN_MBPS)
            return 0;
        double target = rate_round(e->rate * 0.6);
        if (r->probing && now - r->changed_at < 10)
            r->hold = r->hold * 2 > 60 ? 60 : r->hold * 2;
        r->probing = 0;
        r->changed_at = now;
        logmsg("%s: the network delivers %.1f Mbit/s, video bitrate %g -> %g Mbit/s", link_names[l->kind],
               acked, e->rate, target);
        return target;
    }
    if (r->probing && now - r->changed_at >= 10) {
        r->probing = 0;
        r->hold = r->hold / 2 < RATE_HOLD_SEC ? RATE_HOLD_SEC : r->hold / 2;
    }
    if (e->rate >= e->mbps || video < e->rate * 0.2 || now - r->calm_since < r->hold ||
        now - r->changed_at < r->hold)
        return 0;
    double target = rate_round(e->rate * 1.5 > e->mbps ? e->mbps : e->rate * 1.5);
    r->probing = 1;
    r->changed_at = now;
    logmsg("%s: video bitrate %g -> %g Mbit/s", link_names[l->kind], e->rate, target);
    return target;
}

/* ---------------------------------------------------------------- network */

static struct {
    SSL_CTX *tls;
    int tcp, udp; /* listening sockets, -1 when networking is off */
    uint8_t key[CONNECTOR_KEY_LEN];
    uint8_t id[CONNECTOR_ID_LEN];
    char address[256]; /* internet address handed to the iPad, may be empty */
} net = {.tcp = -1, .udp = -1};

static void config_path(char *buf, size_t n, const char *name)
{
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg)
        snprintf(buf, n, "%s/connector/%s", xdg, name);
    else
        snprintf(buf, n, "%s/.config/connector/%s", getenv("HOME") ? getenv("HOME") : ".", name);
}

/* Loads the pairing key, creating it on first run. */
static int load_key(void)
{
    char path[4096];
    config_path(path, sizeof(path), "key");
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = read(fd, net.key, sizeof(net.key));
        close(fd);
        if (n == (ssize_t)sizeof(net.key))
            return 1;
        logmsg("%s is damaged; delete it to pair again", path);
        return 0;
    }
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", path);
    *strrchr(dir, '/') = 0;
    mkdir(dir, 0700);
    if (RAND_bytes(net.key, sizeof(net.key)) != 1)
        return 0;
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0 || write(fd, net.key, sizeof(net.key)) != (ssize_t)sizeof(net.key)) {
        logmsg("cannot write %s: %s", path, strerror(errno));
        if (fd >= 0)
            close(fd);
        return 0;
    }
    close(fd);
    logmsg("new pairing key in %s; connect the iPad by cable once to pair", path);
    return 1;
}

static void load_address(void)
{
    if (opt.address) {
        snprintf(net.address, sizeof(net.address), "%s", opt.address);
        return;
    }
    char path[4096];
    config_path(path, sizeof(path), "address");
    FILE *f = fopen(path, "r");
    if (!f)
        return;
    if (fgets(net.address, sizeof(net.address), f))
        net.address[strcspn(net.address, " \t\r\n")] = 0;
    fclose(f);
}

static unsigned int psk_callback(SSL *ssl, const char *identity, unsigned char *psk, unsigned int max)
{
    if (!identity || strcmp(identity, CONNECTOR_PSK_IDENTITY) != 0 || max < sizeof(net.key))
        return 0;
    memcpy(psk, net.key, sizeof(net.key));
    return sizeof(net.key);
}

static int net_socket(int family, int type)
{
    int fd = socket(family, type | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    int one = 1, zero = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_storage sa = {0};
    socklen_t len;
    if (family == AF_INET6) {
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&sa;
        a->sin6_family = AF_INET6;
        a->sin6_port = htons(opt.listen_port);
        len = sizeof(*a);
    } else {
        struct sockaddr_in *a = (struct sockaddr_in *)&sa;
        a->sin_family = AF_INET;
        a->sin_port = htons(opt.listen_port);
        len = sizeof(*a);
    }
    if (bind(fd, (struct sockaddr *)&sa, len) < 0 || (type == SOCK_STREAM && listen(fd, 4) < 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

static int net_init(void)
{
    if (!load_key())
        return 0;
    uint8_t buf[sizeof(CONNECTOR_ID_SALT) - 1 + CONNECTOR_KEY_LEN], hash[SHA256_DIGEST_LENGTH];
    memcpy(buf, CONNECTOR_ID_SALT, sizeof(CONNECTOR_ID_SALT) - 1);
    memcpy(buf + sizeof(CONNECTOR_ID_SALT) - 1, net.key, CONNECTOR_KEY_LEN);
    SHA256(buf, sizeof(buf), hash);
    memcpy(net.id, hash, CONNECTOR_ID_LEN);
    load_address();

    /* TLS 1.2 PSK: what Network.framework on iOS 12 can do with a shared key. */
    net.tls = SSL_CTX_new(TLS_server_method());
    if (!net.tls)
        return 0;
    SSL_CTX_set_min_proto_version(net.tls, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(net.tls, TLS1_2_VERSION);
    SSL_CTX_set_options(net.tls, SSL_OP_NO_RENEGOTIATION);
#ifdef SSL_OP_IGNORE_UNEXPECTED_EOF /* OpenSSL 3; 1.1 (Ubuntu 20.04) reports such an EOF as SSL_ERROR_SYSCALL */
    SSL_CTX_set_options(net.tls, SSL_OP_IGNORE_UNEXPECTED_EOF);
#endif
    SSL_CTX_set_mode(net.tls, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    if (SSL_CTX_set_cipher_list(net.tls, "PSK-AES128-GCM-SHA256") != 1) {
        logmsg("OpenSSL has no PSK-AES128-GCM-SHA256");
        return 0;
    }
    SSL_CTX_set_psk_server_callback(net.tls, psk_callback);

    net.tcp = net_socket(AF_INET6, SOCK_STREAM);
    if (net.tcp < 0)
        net.tcp = net_socket(AF_INET, SOCK_STREAM);
    net.udp = net_socket(AF_INET, SOCK_DGRAM);
    if (net.tcp < 0) {
        logmsg("cannot listen on TCP port %d: %s; Wi-Fi is off", opt.listen_port, strerror(errno));
        return 0;
    }
    if (net.udp < 0)
        logmsg("cannot listen on UDP port %d: %s; the iPad will not find us by itself",
               opt.listen_port, strerror(errno));
    logmsg("listening on port %d for Wi-Fi/internet%s%s", opt.listen_port,
           net.address[0] ? ", internet address " : "", net.address);
    return 1;
}

static void net_answer_discovery(void)
{
    uint8_t q[16];
    struct sockaddr_in from;
    socklen_t fl = sizeof(from);
    ssize_t n;
    while ((n = recvfrom(net.udp, q, sizeof(q), 0, (struct sockaddr *)&from, &fl)) >= 0) {
        if (n == 4 && memcmp(q, CONNECTOR_DISCOVER_QUERY, 4) == 0) {
            uint8_t r[4 + CONNECTOR_ID_LEN + 2];
            memcpy(r, CONNECTOR_DISCOVER_REPLY, 4);
            memcpy(r + 4, net.id, CONNECTOR_ID_LEN);
            r[4 + CONNECTOR_ID_LEN] = opt.listen_port >> 8;
            r[5 + CONNECTOR_ID_LEN] = opt.listen_port & 255;
            sendto(net.udp, r, sizeof(r), 0, (struct sockaddr *)&from, fl);
        }
        fl = sizeof(from);
    }
}

/* Private, link-local and unique-local addresses count as the same network.
 * Tailscale Funnel connections arrive from localhost and count as internet. */
static int classify_peer(const struct sockaddr_storage *sa, char *text, size_t n)
{
    const uint8_t *v4 = NULL;
    if (sa->ss_family == AF_INET) {
        v4 = (const uint8_t *)&((const struct sockaddr_in *)sa)->sin_addr;
    } else {
        const struct in6_addr *a = &((const struct sockaddr_in6 *)sa)->sin6_addr;
        if (IN6_IS_ADDR_V4MAPPED(a)) {
            v4 = a->s6_addr + 12;
        } else {
            inet_ntop(AF_INET6, a, text, n);
            return IN6_IS_ADDR_LINKLOCAL(a) || (a->s6_addr[0] & 0xfe) == 0xfc ? LINK_LAN : LINK_INTERNET;
        }
    }
    inet_ntop(AF_INET, v4, text, n);
    int lan = v4[0] == 10 || (v4[0] == 172 && (v4[1] & 0xf0) == 16) ||
              (v4[0] == 192 && v4[1] == 168) || (v4[0] == 169 && v4[1] == 254);
    return lan ? LINK_LAN : LINK_INTERNET;
}

/* Accepts an iPad connecting over the network. Returns 1 if *link is now that connection. */
static int net_accept(Display *dpy, Link *link)
{
    struct sockaddr_storage sa;
    socklen_t sl = sizeof(sa);
    int fd = accept4(net.tcp, (struct sockaddr *)&sa, &sl, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0)
        return 0;
    char peer[INET6_ADDRSTRLEN] = "?";
    int kind = classify_peer(&sa, peer, sizeof(peer));
    if (link->fd >= 0 && link->kind == LINK_USB) {
        close(fd); /* the cable is better; the app drops Wi-Fi itself while on USB */
        return 0;
    }
    int one = 1, idle = 5, intvl = 2, cnt = 3, user_timeout = 10000, sndbuf = 2 << 20;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
    setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof(user_timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    SSL *ssl = SSL_new(net.tls);
    SSL_set_fd(ssl, fd);
    double deadline = now_sec() + HANDSHAKE_TIMEOUT_SEC;
    for (;;) {
        int r = SSL_accept(ssl);
        if (r == 1)
            break;
        int e = SSL_get_error(ssl, r);
        int want = e == SSL_ERROR_WANT_READ ? POLLIN : e == SSL_ERROR_WANT_WRITE ? POLLOUT : 0;
        if (want && wait_fd(fd, want, deadline))
            continue;
        logmsg("%s: TLS handshake failed (an iPad not paired with this computer? "
               "connect it by cable once)", peer);
        ERR_clear_error();
        SSL_free(ssl);
        close(fd);
        return 0;
    }
    if (link->fd >= 0) {
        logmsg("the iPad reconnected, dropping the old %s connection", link_names[link->kind]);
        link_close(dpy, link);
    }
    *link = (Link){.fd = fd, .ssl = ssl, .kind = kind};
    logmsg("connected over %s from %s", link_names[kind], peer);
    return 1;
}

/* Gives the iPad what it needs to connect without the cable next time. */
static int send_pair(Link *l)
{
    char name[256] = "";
    gethostname(name, sizeof(name) - 1);
    size_t nl = strlen(name), al = strlen(net.address);
    if (nl > 255)
        nl = 255;
    if (al > 255)
        al = 255;
    uint8_t p[2 + CONNECTOR_KEY_LEN + 1 + 255 + 1 + 255];
    size_t o = 0;
    p[o++] = opt.listen_port >> 8;
    p[o++] = opt.listen_port & 255;
    memcpy(p + o, net.key, CONNECTOR_KEY_LEN);
    o += CONNECTOR_KEY_LEN;
    p[o++] = (uint8_t)nl;
    memcpy(p + o, name, nl);
    o += nl;
    p[o++] = (uint8_t)al;
    memcpy(p + o, net.address, al);
    o += al;
    return send_msg(l, MSG_PAIR, p, (uint32_t)o);
}

/* ---------------------------------------------------------------- display */

/* What the iPad asked for; turned into a virtual display mode by display_apply(). */
typedef struct {
    int native_w, native_h; /* landscape, pixels */
    int scale;              /* percent */
    int portrait;
    int mirror;             /* show the main screen instead of the virtual one */
    char applied[32];       /* mode currently set by us, "" if off */
} VirtualDisplay;

static int run_display_script(const char *arg)
{
    char cmd[4300];
    snprintf(cmd, sizeof(cmd), "'%s' %s", opt.display_script, arg);
    int rc = system(cmd);
    if (rc != 0)
        logmsg("display script failed: %s", cmd);
    return rc == 0;
}

static void display_apply(VirtualDisplay *d)
{
    if (!opt.manage_display)
        return;
    int scale = d->scale < 50 ? 50 : d->scale > 400 ? 400 : d->scale;
    int w = d->native_w * 100 / scale, h = d->native_h * 100 / scale;
    if (d->portrait) {
        int t = w;
        w = h;
        h = t;
    }
    w = (w + 4) / 8 * 8; /* CVT wants a multiple of 8 */
    h = (h + 1) / 2 * 2;
    char mode[32];
    snprintf(mode, sizeof(mode), "%dx%d", w, h);
    if (strcmp(mode, d->applied) == 0)
        return;
    char arg[48];
    snprintf(arg, sizeof(arg), "on %s", mode);
    logmsg("virtual display -> %s (%d%%, %s)", mode, scale, d->portrait ? "portrait" : "landscape");
    if (run_display_script(arg))
        snprintf(d->applied, sizeof(d->applied), "%s", mode);
}

static void display_off(VirtualDisplay *d)
{
    if (!opt.manage_display)
        return;
    logmsg("virtual display off");
    run_display_script("off");
    d->applied[0] = 0;
}

/* ---------------------------------------------------------------- keyboard */

/* Keycodes without symbols, borrowed for characters the current layout lacks
 * (as xdotool does). They keep their symbol until the iPad disconnects, so
 * repeated characters don't remap the keyboard every time. */
#define SCRATCH_KEYS 16
static struct {
    KeyCode code[SCRATCH_KEYS];
    KeySym sym[SCRATCH_KEYS];
    int count, next, scanned;
} scratch;

static int scratch_key(Display *dpy, KeySym sym, KeyCode *out)
{
    if (!scratch.scanned) {
        scratch.scanned = 1;
        int min, max, per;
        XDisplayKeycodes(dpy, &min, &max);
        KeySym *map = XGetKeyboardMapping(dpy, min, max - min + 1, &per);
        for (int kc = max; map && kc >= min && scratch.count < SCRATCH_KEYS; kc--) {
            int empty = 1;
            for (int i = 0; i < per; i++)
                empty &= map[(kc - min) * per + i] == NoSymbol;
            if (empty)
                scratch.code[scratch.count++] = kc;
        }
        if (map)
            XFree(map);
    }
    for (int i = 0; i < scratch.count; i++) {
        if (scratch.sym[i] == sym) {
            *out = scratch.code[i];
            return 1;
        }
    }
    if (!scratch.count)
        return 0;
    int i = scratch.next;
    scratch.next = (i + 1) % scratch.count;
    KeySym syms[2] = {sym, sym};
    XChangeKeyboardMapping(dpy, scratch.code[i], 2, syms, 1);
    scratch.sym[i] = sym;
    XSync(dpy, False);
    usleep(20000); /* let applications see the new mapping before the key arrives */
    *out = scratch.code[i];
    return 1;
}

static void scratch_reset(Display *dpy)
{
    KeySym none = NoSymbol;
    for (int i = 0; i < scratch.count; i++) {
        if (scratch.sym[i]) {
            XChangeKeyboardMapping(dpy, scratch.code[i], 1, &none, 1);
            scratch.sym[i] = 0;
        }
    }
    XFlush(dpy);
}

/* The level Shift selects on this key, or -1. */
static int shift_level(XkbDescPtr xkb, int kc, int group)
{
    XkbKeyTypePtr t = XkbKeyKeyType(xkb, kc, group);
    for (int i = 0; i < t->map_count; i++)
        if (t->map[i].active && t->map[i].mods.mask == ShiftMask)
            return t->map[i].level;
    return -1;
}

/* Finds a key that produces `sym` (or the same character) in `group`, or in
 * any group if group < 0. Sets *shift if Shift is needed and *found_group. */
static int find_key(XkbDescPtr xkb, KeySym sym, int group, KeyCode *code, int *shift, int *found_group)
{
    uint32_t want = xkb_keysym_to_utf32(sym);
    for (int pass = 0; pass < 2; pass++) {
        for (int kc = xkb->min_key_code; kc <= xkb->max_key_code; kc++) {
            int ng = XkbKeyNumGroups(xkb, kc);
            for (int g = 0; g < ng; g++) {
                if (group >= 0 && g != group % ng)
                    continue;
                int level = pass ? shift_level(xkb, kc, g) : 0;
                if (level < 0 || level >= XkbKeyGroupWidth(xkb, kc, g))
                    continue;
                KeySym ks = XkbKeySymEntry(xkb, kc, level, g);
                if (ks == sym || (want && xkb_keysym_to_utf32(ks) == want)) {
                    *code = kc;
                    *shift = pass;
                    *found_group = g;
                    return 1;
                }
            }
        }
    }
    return 0;
}

/* Presses and releases `sym` with modifiers: on its key in the current layout;
 * else on its key in another layout, switching to it for this one keystroke
 * (shortcuts stay in the current layout: apps match Ctrl+С as Ctrl+C);
 * else on a borrowed spare keycode. */
static void send_key(Display *dpy, KeySym sym, int mods, int text)
{
    static const KeySym modsyms[4] = {XK_Shift_L, XK_Control_L, XK_Alt_L, XK_Super_L};
    KeyCode code = 0;
    int shift = 0, found = 0, group = 0, current = 0;
    XkbDescPtr xkb = XkbGetMap(dpy, XkbKeyTypesMask | XkbKeySymsMask, XkbUseCoreKbd);
    if (xkb) {
        XkbStateRec st;
        XkbGetState(dpy, XkbUseCoreKbd, &st);
        current = st.group;
        found = find_key(xkb, sym, current, &code, &shift, &group) ||
                find_key(xkb, sym, -1, &code, &shift, &group);
        XkbFreeKeyboard(xkb, 0, True);
    }
    if (!found && !scratch_key(dpy, sym, &code)) {
        logmsg("cannot type keysym 0x%lx: no free keycode", (unsigned long)sym);
        return;
    }
    int switch_group = found && text && group != current;
    if (switch_group)
        XkbLockGroup(dpy, XkbUseCoreKbd, group);
    if (shift)
        mods |= MOD_SHIFT;
    for (int i = 0; i < 4; i++)
        if (mods & (1 << i))
            XTestFakeKeyEvent(dpy, XKeysymToKeycode(dpy, modsyms[i]), True, CurrentTime);
    XTestFakeKeyEvent(dpy, code, True, CurrentTime);
    XTestFakeKeyEvent(dpy, code, False, CurrentTime);
    for (int i = 3; i >= 0; i--)
        if (mods & (1 << i))
            XTestFakeKeyEvent(dpy, XKeysymToKeycode(dpy, modsyms[i]), False, CurrentTime);
    if (switch_group)
        XkbLockGroup(dpy, XkbUseCoreKbd, current);
}

static void type_text(Display *dpy, const uint8_t *s, uint32_t len)
{
    for (uint32_t i = 0; i < len;) {
        uint32_t cp = s[i];
        int n = cp < 0x80 ? 1 : (cp & 0xe0) == 0xc0 ? 2 : (cp & 0xf0) == 0xe0 ? 3 : (cp & 0xf8) == 0xf0 ? 4 : 0;
        if (!n || i + n > len)
            return;
        if (n > 1)
            cp &= 0x7f >> n;
        for (int k = 1; k < n; k++)
            cp = cp << 6 | (s[i + k] & 0x3f);
        i += n;
        KeySym sym = cp == '\n' || cp == '\r' ? XK_Return
                     : cp == '\t'             ? XK_Tab
                     : cp < 0x20 || cp == 0x7f ? NoSymbol
                     : (cp < 0x7f || (cp >= 0xa0 && cp <= 0xff)) ? cp
                                                                  : 0x01000000 | cp;
        if (sym != NoSymbol)
            send_key(dpy, sym, 0, 1);
    }
}

/* ---------------------------------------------------------------- app signature */

/* A free Apple ID signs the iPad app for 7 days; after that it won't open.
 * The app reports the date, and we remind the user while there is still time
 * to re-sign (scripts/ipad-install needs the cable). */
static struct {
    time_t expires;   /* 0 if unknown */
    time_t notified;  /* last reminder */
} sig;

static void sig_load(void)
{
    char path[4096];
    config_path(path, sizeof(path), "app-expires");
    FILE *f = fopen(path, "r");
    if (f) {
        long long t = 0;
        if (fscanf(f, "%lld", &t) == 1)
            sig.expires = (time_t)t;
        fclose(f);
    }
}

static void sig_store(uint32_t expires)
{
    if (!expires || (time_t)expires == sig.expires)
        return;
    sig.expires = expires;
    sig.notified = 0;
    char path[4096], date[64];
    config_path(path, sizeof(path), "app-expires");
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%lld\n", (long long)expires);
        fclose(f);
    }
    time_t t = expires;
    strftime(date, sizeof(date), "%Y-%m-%d %H:%M", localtime(&t));
    logmsg("iPad app signature valid until %s", date);
}

/* Shows a desktop notification without waiting for it (notify-send can take
 * seconds); the previous one is reaped on the next call. */
static void notify(const char *title, const char *body)
{
    static pid_t pid;
    if (pid > 0)
        waitpid(pid, NULL, WNOHANG);
    char *argv[] = {"notify-send", "-i", "video-display", "-a", "Connector", (char *)title, (char *)body, NULL};
    extern char **environ;
    if (posix_spawnp(&pid, "notify-send", NULL, NULL, argv, environ) != 0)
        pid = 0;
}

/* Called now and then: a reminder a day before expiry, and every few hours after. */
static void sig_check(void)
{
    time_t now = time(NULL);
    if (!sig.expires || now < sig.expires - 24 * 3600 || now - sig.notified < 6 * 3600)
        return;
    sig.notified = now;
    int ru = getenv("LANG") && strncmp(getenv("LANG"), "ru", 2) == 0;
    char date[64], body[8192], cmd[4200];
    strftime(date, sizeof(date), "%d.%m %H:%M", localtime(&sig.expires));
    /* installed: on PATH; a source checkout: the script itself */
    if (strncmp(opt.root, "/usr/", 5) == 0)
        snprintf(cmd, sizeof(cmd), "connector-ipad-install");
    else
        snprintf(cmd, sizeof(cmd), "%s/scripts/ipad-install", opt.root);
    if (now < sig.expires)
        snprintf(body, sizeof(body),
                 ru ? "Подпись приложения на iPad истекает %s. Подключите iPad кабелем и запустите\n%s"
                    : "The iPad app's signature expires %s. Plug the iPad in and run\n%s",
                 date, cmd);
    else
        snprintf(body, sizeof(body),
                 ru ? "Подпись приложения на iPad истекла, оно не откроется. Подключите iPad кабелем и запустите\n%s"
                    : "The iPad app's signature has expired; it won't open. Plug the iPad in and run\n%s",
                 cmd);
    logmsg("%s", body);
    notify(ru ? "Connector: продлите подпись приложения" : "Connector: re-sign the iPad app", body);
}

/* ---------------------------------------------------------------- input */

typedef struct {
    uint8_t buf[4096];
    size_t len;
    int want_keyframe;       /* send an IDR with the next frame */
    int keyframe_requested;  /* the iPad asked for one; rate-limited in the main loop */
    int reinit_encoder;
    VirtualDisplay *display;
} Input;

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static void click(Display *dpy, unsigned button, int count)
{
    for (int i = 0; i < count; i++) {
        XTestFakeButtonEvent(dpy, button, True, CurrentTime);
        XTestFakeButtonEvent(dpy, button, False, CurrentTime);
    }
}

static void handle_message(X11 *x, Input *in, int type, const uint8_t *p, uint32_t len)
{
    Rect a = x->area;
    switch (type) {
    case MSG_HELLO:
        if (len >= 8) {
            logmsg("iPad screen %ux%u", rd32(p), rd32(p + 4));
            in->display->native_w = rd32(p);
            in->display->native_h = rd32(p + 4);
        }
        /* the display mode is applied once MSG_SETTINGS (sent right after) arrives */
        in->want_keyframe = 1;
        break;
    case MSG_SETTINGS:
        if (len >= 4) {
            VirtualDisplay *d = in->display;
            int cq = quality_cq[p[2] > 2 ? 2 : p[2]];
            int mirror = len >= 5 && p[4];
            logmsg("iPad settings: scale %d%%, quality %d, %s%s", rd16(p), p[2],
                   p[3] ? "portrait" : "landscape", mirror ? ", mirroring the main screen" : "");
            if (cq != opt.quality) {
                opt.quality = cq;
                in->reinit_encoder = 1;
            }
            d->scale = rd16(p);
            d->portrait = p[3] != 0;
            char want[64];
            if (!mirror || !main_output(x, want, sizeof(want)))
                snprintf(want, sizeof(want), "%s", opt.output);
            if (strcmp(want, x->output) != 0) {
                snprintf(x->output, sizeof(x->output), "%s", want);
                x->geometry_dirty = 1;
            }
            d->mirror = mirror;
            /* Mirroring leaves the virtual display as it is: its windows stay
             * there for when the iPad switches back to it. */
            if (!mirror)
                display_apply(d);
        }
        break;
    case MSG_KEY:
        if (len >= 5)
            send_key(x->dpy, rd32(p), p[4], 0);
        break;
    case MSG_TEXT:
        type_text(x->dpy, p, len);
        break;
    case MSG_MOUSE_REL:
        if (len >= 4 && a.w) {
            Window rw, cw;
            int px, py, wx, wy;
            unsigned mask;
            if (!XQueryPointer(x->dpy, x->root, &rw, &cw, &px, &py, &wx, &wy, &mask))
                break;
            /* Keep the pointer on the iPad's screen, where the user can see it. */
            px += (int16_t)rd16(p);
            py += (int16_t)rd16(p + 2);
            px = px < a.x ? a.x : px >= a.x + a.w ? a.x + a.w - 1 : px;
            py = py < a.y ? a.y : py >= a.y + a.h ? a.y + a.h - 1 : py;
            XTestFakeMotionEvent(x->dpy, -1, px, py, CurrentTime);
        }
        break;
    case MSG_APP_INFO:
        if (len >= 4) {
            if (len > 4)
                logmsg("iPad app: %.*s", (int)(len - 4), p + 4);
            sig_store(rd32(p));
            sig_check();
        }
        break;
    case MSG_LOG:
        /* one host log line per app log line */
        for (uint32_t i = 0; i < len;) {
            uint32_t j = i;
            while (j < len && p[j] != '\n')
                j++;
            if (j > i)
                logmsg("iPad: %.*s", (int)(j - i), p + i);
            i = j + 1;
        }
        break;
    case MSG_MOUSE_MOVE:
        if (len >= 4 && a.w) {
            int px = a.x + (int)((int64_t)rd16(p) * (a.w - 1) / 65535);
            int py = a.y + (int)((int64_t)rd16(p + 2) * (a.h - 1) / 65535);
            XTestFakeMotionEvent(x->dpy, -1, px, py, CurrentTime);
        }
        break;
    case MSG_BUTTON:
        if (len >= 2 && p[0] >= 1 && p[0] <= 3)
            XTestFakeButtonEvent(x->dpy, p[0], p[1] ? True : False, CurrentTime);
        break;
    case MSG_SCROLL:
        if (len >= 4) {
            int dx = (int16_t)rd16(p), dy = (int16_t)rd16(p + 2);
            click(x->dpy, dy > 0 ? 5 : 4, abs(dy));
            click(x->dpy, dx > 0 ? 7 : 6, abs(dx));
        }
        break;
    case MSG_KEYFRAME:
        in->keyframe_requested = 1;
        break;
    }
}

/* Reads whatever the iPad sent. Returns 0 when the connection is gone. */
static int input_read(X11 *x, Input *in, Link *l)
{
    /* Loop until the socket is empty: TLS may hold decrypted bytes that poll() can't see. */
    for (;;) {
        ssize_t n = link_recv(l, in->buf + in->len, sizeof(in->buf) - in->len);
        if (n < 0)
            return 0;
        if (n == 0)
            break;
        in->len += n;
        size_t off = 0;
        while (in->len - off >= CONNECTOR_HDR_LEN) {
            uint32_t len = rd32(in->buf + off + 1);
            if (len > sizeof(in->buf) - CONNECTOR_HDR_LEN) {
                logmsg("recv: bad message from the app");
                return 0;
            }
            if (in->len - off < CONNECTOR_HDR_LEN + len)
                break;
            handle_message(x, in, in->buf[off], in->buf + off + CONNECTOR_HDR_LEN, len);
            off += CONNECTOR_HDR_LEN + len;
        }
        memmove(in->buf, in->buf + off, in->len - off);
        in->len -= off;
    }
    XFlush(x->dpy);
    return 1;
}

/* ---------------------------------------------------------------- self check */

/* What works on this machine, for bug reports: connector-host --check. */
static int self_check(X11 *x)
{
    printf("connector-host %s\n", CONNECTOR_VERSION);
    const char *session = getenv("XDG_SESSION_TYPE");
    printf("session: %s%s\n", session ? session : "?",
           session && strcmp(session, "x11") != 0 ? " (needs X11)" : "");
    int a, b, c, d, ok = 1;
    int shm = XShmQueryExtension(x->dpy), test = XTestQueryExtension(x->dpy, &a, &b, &c, &d),
        randr = XRRQueryExtension(x->dpy, &a, &b), fixes = XFixesQueryExtension(x->dpy, &a, &b);
    printf("X11 extensions: MIT-SHM %s, XTEST %s, RANDR %s, XFIXES %s\n", shm ? "ok" : "MISSING",
           test ? "ok" : "MISSING", randr ? "ok" : "MISSING", fixes ? "ok" : "MISSING");
    ok &= shm && test && randr && fixes;

    printf("outputs:\n");
    fflush(stdout);
    list_outputs(x);
    Rect r;
    if (find_output(x, &r))
        printf("virtual monitor %s: on, %dx%d+%d+%d\n", x->output, r.w, r.h, r.x, r.y);
    else
        printf("virtual monitor %s: off (normal while no iPad is connected)\n", x->output);

    printf("encoders (1280x720 test):\n");
    static const char *const names[] = {"h264_nvenc", "h264_vaapi", "libx264"};
    int any = 0;
    for (int i = 0; i < 3; i++) {
        Encoder e = {.mbps = 10};
        fflush(stdout);
        int works = encoder_try(&e, names[i], 1280, 720);
        encoder_close(&e);
        printf("  %-11s %s\n", names[i], works ? "ok" : "not available");
        any |= works;
    }
    ok &= any;

    usbmuxd_device_info_t *list = NULL;
    int n = usbmuxd_get_device_list(&list);
    if (n < 0) {
        printf("usbmuxd: not running (fine if no iPad is plugged in: it starts with one; "
               "if one is, install usbmuxd)\n");
    } else {
        int usb = 0;
        for (int i = 0; i < n; i++)
            usb += list[i].conn_type == CONNECTION_TYPE_USB;
        printf("usbmuxd: ok, %d iOS device(s) on USB\n", usb);
        usbmuxd_device_list_free(&list);
    }

    int fd = net_socket(AF_INET6, SOCK_STREAM);
    if (fd < 0)
        fd = net_socket(AF_INET, SOCK_STREAM);
    if (fd >= 0)
        printf("port %d: free\n", opt.listen_port);
    else
        printf("port %d: %s%s\n", opt.listen_port, strerror(errno),
               errno == EADDRINUSE ? " (the service is probably running: fine)" : "");
    if (fd >= 0)
        close(fd);

    char path[4096];
    config_path(path, sizeof(path), "key");
    printf("pairing key: %s\n", access(path, R_OK) == 0 ? "present" : "none yet (pair by cable)");
    sig_load();
    if (sig.expires) {
        char date[64];
        strftime(date, sizeof(date), "%Y-%m-%d %H:%M", localtime(&sig.expires));
        printf("iPad app signature: valid until %s%s\n", date, sig.expires < time(NULL) ? " (EXPIRED)" : "");
    } else {
        printf("iPad app signature: unknown\n");
    }
    printf("%s\n", ok ? "result: ok" : "result: PROBLEMS above");
    return ok ? 0 : 1;
}

/* ---------------------------------------------------------------- main loop */

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [options]\n"
            "  -o, --output NAME    xrandr output to stream (default %s)\n"
            "  -f, --fps N          frame rate (default %d)\n"
            "  -b, --bitrate MBPS   peak bitrate in Mbit/s (default %d)\n"
            "  -q, --quality N      constant quality, lower is sharper (default %d)\n"
            "  -e, --encoder NAME   auto | nvenc | vaapi | x264 | <ffmpeg encoder> (default auto:\n"
            "                       the first that works of nvenc, vaapi, x264)\n"
            "  -p, --port N         TCP port of the iPad app (default %d)\n"
            "  -n, --no-network     USB only: don't accept the iPad over Wi-Fi/internet\n"
            "  -U, --no-usb         network only: don't look for the iPad on USB\n"
            "  -P, --listen-port N  TCP/UDP port for Wi-Fi/internet (default %d)\n"
            "  -a, --address HOST[:PORT]\n"
            "                       internet address of this computer, handed to the iPad\n"
            "                       when pairing (default: ~/.config/connector/address)\n"
            "      --lan-bitrate MBPS       peak bitrate over Wi-Fi (default %d)\n"
            "      --internet-bitrate MBPS  peak bitrate over the internet (default %d)\n"
            "  -m, --manage-display turn the virtual display on/off and pick its mode\n"
            "                       from the iPad's settings (used by the autostart service)\n"
            "  -l, --list           list xrandr outputs and exit\n"
            "      --check          check what works here (X11, port, encoders, USB) and exit\n"
            "  -v, --verbose        print stats every 5 seconds; -vv also the Wi-Fi/internet\n"
            "                       bitrate control every second\n"
            "  -V, --version        print the version and exit\n",
            argv0, opt.output, opt.fps, opt.bitrate_mbps, opt.quality, opt.port, opt.listen_port, opt.lan_mbps,
            opt.internet_mbps);
}

int main(int argc, char **argv)
{
    static const struct option longopts[] = {
        {"output", required_argument, 0, 'o'},  {"fps", required_argument, 0, 'f'},
        {"bitrate", required_argument, 0, 'b'}, {"quality", required_argument, 0, 'q'},
        {"encoder", required_argument, 0, 'e'}, {"port", required_argument, 0, 'p'},
        {"list", no_argument, 0, 'l'},          {"verbose", no_argument, 0, 'v'},
        {"manage-display", no_argument, 0, 'm'}, {"no-network", no_argument, 0, 'n'},
        {"no-usb", no_argument, 0, 'U'},
        {"address", required_argument, 0, 'a'}, {"listen-port", required_argument, 0, 'P'},
        {"lan-bitrate", required_argument, 0, 'L'},
        {"internet-bitrate", required_argument, 0, 'I'},
        {"check", no_argument, 0, 'C'},         {"version", no_argument, 0, 'V'},
        {"help", no_argument, 0, 'h'},          {0, 0, 0, 0},
    };
    int list_only = 0, check_only = 0, c;
    while ((c = getopt_long(argc, argv, "o:f:b:q:e:p:P:a:lmnUvVh", longopts, NULL)) != -1) {
        switch (c) {
        case 'o': opt.output = optarg; break;
        case 'f': opt.fps = atoi(optarg); break;
        case 'b': opt.bitrate_mbps = atoi(optarg); break;
        case 'q': opt.quality = atoi(optarg); break;
        case 'e': opt.encoder = optarg; break;
        case 'p': opt.port = atoi(optarg); break;
        case 'l': list_only = 1; break;
        case 'v': opt.verbose++; break;
        case 'm': opt.manage_display = 1; break;
        case 'n': opt.network = 0; break;
        case 'U': opt.usb = 0; break;
        case 'a': opt.address = optarg; break;
        case 'P': opt.listen_port = atoi(optarg); break;
        case 'L': opt.lan_mbps = atoi(optarg); break;
        case 'I': opt.internet_mbps = atoi(optarg); break;
        case 'C': check_only = 1; break;
        case 'V': printf("connector-host %s\n", CONNECTOR_VERSION); return 0;
        default: usage(argv[0]); return c == 'h' ? 0 : 2;
        }
    }
    if (opt.fps < 1 || opt.fps > 240 || opt.bitrate_mbps < 1 || opt.lan_mbps < 1 || opt.internet_mbps < 1 ||
        opt.listen_port < 1 || opt.listen_port > 65535 || (!opt.network && !opt.usb)) {
        usage(argv[0]);
        return 2;
    }

    X11 x = {0};
    x.dpy = XOpenDisplay(NULL);
    if (!x.dpy) {
        fprintf(stderr, "cannot open X display (DISPLAY=%s)\n", getenv("DISPLAY"));
        return 1;
    }
    x.root = DefaultRootWindow(x.dpy);
    {
        /* scripts/connector-display next to host/connector-host */
        char exe[3072];
        ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
        exe[n > 0 ? n : 0] = 0;
        char *slash = strrchr(exe, '/');
        if (slash)
            *slash = 0;
        snprintf(opt.root, sizeof(opt.root), "%s", exe);
        char *up = strrchr(opt.root, '/'); /* host/ -> project root */
        if (up)
            *up = 0;
        snprintf(opt.display_script, sizeof(opt.display_script), "%s/scripts/connector-display", opt.root);
    }
    snprintf(x.output, sizeof(x.output), "%s", opt.output);
    if (list_only) {
        list_outputs(&x);
        return 0;
    }
    if (check_only)
        return self_check(&x);
    logmsg("connector-host %s", CONNECTOR_VERSION);

    int err_base, ev, er, maj, min;
    if (!XShmQueryExtension(x.dpy) || !XTestQueryExtension(x.dpy, &ev, &er, &maj, &min) ||
        !XRRQueryExtension(x.dpy, &x.randr_event_base, &err_base) ||
        !XFixesQueryExtension(x.dpy, &x.xfixes_event_base, &err_base)) {
        fprintf(stderr, "X server lacks MIT-SHM / XTEST / RANDR / XFIXES\n");
        return 1;
    }
    XRRSelectInput(x.dpy, x.root, RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask |
                                      RROutputChangeNotifyMask);
    XFixesSelectCursorInput(x.dpy, x.root, XFixesDisplayCursorNotifyMask);
    cursor_update(&x);
    x.geometry_dirty = 1;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    if (opt.network && !net_init())
        logmsg("Wi-Fi/internet connections are off, USB only");
    sig_load();
    double next_sig_check = 0;

    Encoder enc = {.mbps = opt.bitrate_mbps, .rate = opt.bitrate_mbps};
    RateCtl rate = {0};
    VirtualDisplay display = {.native_w = 2048, .native_h = 1536, .scale = CONNECTOR_SCALE_DEFAULT};
    Input in = {.display = &display};
    double disconnected_at = 0;
    if (opt.manage_display)
        display_off(&display);
    Link link = {.fd = -1};
    int link_new = 0;
    int need_config = 1;
    uint8_t *prev = NULL;      /* last frame sent, for change detection */
    size_t frame_bytes = 0;
    double next_tick = now_sec(), next_connect = 0, last_send = 0, last_idr = 0;
    int waiting_logged = 0, output_logged = 0;

    /* stats */
    double stat_t0 = now_sec(), enc_time = 0;
    long stat_frames = 0, stat_bytes = 0, stat_skipped = 0;

    while (!quit_requested) {
        x11_drain_events(&x);

        if (x.geometry_dirty) {
            x.geometry_dirty = 0;
            Rect r;
            find_output(&x, &r);
            if (memcmp(&r, &x.area, sizeof(r)) != 0) {
                x.area = r;
                capture_free(&x);
                encoder_close(&enc);
                free(prev);
                prev = NULL;
                if (r.w) {
                    logmsg("output %s: %dx%d+%d+%d", x.output, r.w, r.h, r.x, r.y);
                    if (!capture_init(&x) || !encoder_open(&enc, r.w, r.h)) {
                        logmsg("cannot set up capture/encoder");
                        return 1;
                    }
                    frame_bytes = (size_t)x.img->bytes_per_line * r.h;
                    prev = calloc(1, frame_bytes);
                    need_config = 1;
                    output_logged = 0;
                }
            }
            if (!x.area.w && !output_logged && !opt.manage_display) {
                logmsg("output %s is not active - run: connector-display on", x.output);
                output_logged = 1;
            }
        }

        if (in.reinit_encoder && enc.ctx) {
            in.reinit_encoder = 0;
            if (!encoder_open(&enc, x.area.w, x.area.h)) {
                logmsg("cannot reopen encoder");
                return 1;
            }
            in.want_keyframe = 1;
        }

        double now = now_sec();
        if (link.fd < 0 && display.applied[0] && now - disconnected_at > opt.grace)
            display_off(&display);
        if (now >= next_sig_check) {
            next_sig_check = now + 600;
            sig_check();
        }

        /* The cable is tried even during a network session: it wins. */
        if (opt.usb && now >= next_connect && (link.fd < 0 || link.kind != LINK_USB)) {
            next_connect = now + (link.fd < 0 ? 1.0 : 2.0);
            int fd = device_connect();
            if (fd >= 0) {
                if (link.fd >= 0) {
                    logmsg("cable connected, dropping the %s connection", link_names[link.kind]);
                    link_close(x.dpy, &link);
                }
                link = (Link){.fd = fd, .kind = LINK_USB};
                link_new = 1;
            } else if (link.fd < 0 && !waiting_logged) {
                logmsg(net.tcp >= 0 ? "waiting for the iPad (cable, or Wi-Fi/internet once paired by cable; "
                                      "Connector app open)..."
                                    : "waiting for the iPad (cable plugged in, Connector app open)...");
                waiting_logged = 1;
            }
        }

        if (link_new) {
            link_new = 0;
            need_config = 1;
            in.len = 0;
            in.want_keyframe = 1;
            in.keyframe_requested = 0;
            waiting_logged = 0;
            int mbps = link.kind == LINK_USB ? opt.bitrate_mbps
                       : link.kind == LINK_LAN ? opt.lan_mbps : opt.internet_mbps;
            if (mbps != enc.mbps) {
                enc.mbps = mbps;
                enc.rate = mbps;
                in.reinit_encoder = 1;
            } else if (enc.rate < mbps && now - disconnected_at > 60) {
                encoder_set_rate(&enc, mbps); /* a new session, not a reconnect */
            }
            rate_start(&rate, now);
            if (link.kind == LINK_USB && net.tcp >= 0 && !send_pair(&link))
                goto disconnected;
        }

        if (link.fd >= 0 && need_config && x.area.w) {
            if (!send_config(&link, x.area.w, x.area.h))
                goto disconnected;
            need_config = 0;
            in.want_keyframe = 1;
        }

        /* Keyframe requests come per broken frame; one IDR answers them all. */
        if (in.keyframe_requested && now - last_idr >= (link.kind == LINK_USB ? 0.25 : 1.0)) {
            in.keyframe_requested = 0;
            in.want_keyframe = 1;
        }

        if (link.fd >= 0 && now >= next_tick) {
            next_tick += 1.0 / opt.fps;
            if (next_tick < now)
                next_tick = now + 1.0 / opt.fps;

            /* Over the network, skip frames while the previous ones are still
             * on their way: queued video is what makes latency grow. */
            int busy_bytes = (int)(enc.rate * 125000 / 12);
            int busy = link.kind != LINK_USB && link_backlog(&link) > (busy_bytes > 96 * 1024 ? busy_bytes : 96 * 1024);
            if (busy) {
                stat_skipped++;
                rate.skipped++;
            }
            else if (x.img && enc.ctx && XShmGetImage(x.dpy, x.root, x.img, x.area.x, x.area.y, AllPlanes)) {
                if (x.cursor_dirty)
                    cursor_update(&x);
                Window rw, cw;
                int px, py, wx, wy;
                unsigned mask;
                if (XQueryPointer(x.dpy, x.root, &rw, &cw, &px, &py, &wx, &wy, &mask))
                    cursor_draw(&x, px, py);

                /* Refresh at least once a second so a lost frame can't stick. */
                int changed = in.want_keyframe || now - last_send > 1.0 ||
                              memcmp(prev, x.img->data, frame_bytes) != 0;
                if (changed) {
                    memcpy(prev, x.img->data, frame_bytes);
                    double t0 = now_sec();
                    if (in.want_keyframe) {
                        last_idr = now;
                        in.keyframe_requested = 0;
                    }
                    int idr = in.want_keyframe;
                    in.want_keyframe = 0;
                    if (!encoder_send(&enc, (uint8_t *)x.img->data, x.img->bytes_per_line, x.area.h, idr)) {
                        logmsg("encode error");
                        return 1;
                    }
                    while (avcodec_receive_packet(enc.ctx, enc.pkt) == 0) {
                        int ok = send_msg(&link, MSG_VIDEO, enc.pkt->data, enc.pkt->size);
                        stat_bytes += enc.pkt->size;
                        rate.video += enc.pkt->size;
                        rate.sent += CONNECTOR_HDR_LEN + enc.pkt->size;
                        av_packet_unref(enc.pkt);
                        if (!ok)
                            goto disconnected;
                    }
                    enc_time += now_sec() - t0;
                    stat_frames++;
                    last_send = now;
                }
            }
        }

        if (link.fd >= 0 && link.kind != LINK_USB && enc.live_rate) {
            double r = rate_update(&rate, &link, &enc, now);
            if (r)
                encoder_set_rate(&enc, r);
        }

        if (opt.verbose && link.fd >= 0 && now - stat_t0 >= 5.0) {
            double dt = now - stat_t0;
            logmsg("%s: %.1f fps, %.1f of max %g Mbit/s, encode+send %.1f ms/frame%s", link_names[link.kind],
                   stat_frames / dt, stat_bytes * 8 / dt / 1e6, enc.rate,
                   stat_frames ? enc_time / stat_frames * 1000 : 0,
                   stat_skipped ? ", skipping frames: network busy" : "");
            stat_t0 = now;
            stat_frames = stat_bytes = stat_skipped = 0;
            enc_time = 0;
        }

        /* Sleep until the next frame (or a moment, when idle), waking up early
         * for touch input and the network. poll() skips fds that are -1. */
        int timeout_ms = link.fd < 0 ? 50 : (int)((next_tick - now_sec()) * 1000);
        if (timeout_ms < 0)
            timeout_ms = 0;
        struct pollfd pfd[4] = {{link.fd, POLLIN, 0}, {ConnectionNumber(x.dpy), POLLIN, 0},
                                {net.tcp, POLLIN, 0}, {net.udp, POLLIN, 0}};
        if (poll(pfd, 4, timeout_ms) > 0) {
            if (pfd[3].revents & POLLIN)
                net_answer_discovery();
            if ((pfd[2].revents & POLLIN) && net_accept(x.dpy, &link)) {
                link_new = 1;
                continue;
            }
            if (link.fd >= 0 && (pfd[0].revents & (POLLIN | POLLHUP | POLLERR)) &&
                !input_read(&x, &in, &link))
                goto disconnected;
        }
        continue;

    disconnected:
        logmsg("iPad disconnected (%s)", link_names[link.kind]);
        link_close(x.dpy, &link);
        disconnected_at = now_sec();
        next_connect = now_sec() + 1.0;
    }

    if (link.fd >= 0)
        link_close(x.dpy, &link);
    if (display.applied[0])
        display_off(&display);
    encoder_close(&enc);
    capture_free(&x);
    XCloseDisplay(x.dpy);
    return 0;
}
