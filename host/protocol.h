/*
 * Wire protocol shared by connector-host (Linux) and the iPad app.
 *
 * Every message: [u8 type][u32 big-endian payload length][payload].
 *
 * Two ways to connect, same messages on both:
 *   USB    : the host connects to the iPad through usbmuxd; the iPad app
 *            listens on CONNECTOR_PORT on its loopback interface. Plain TCP.
 *   network: the iPad connects to the host's CONNECTOR_PORT over Wi-Fi or the
 *            internet. TLS 1.2 with a pre-shared key (cipher
 *            PSK-AES128-GCM-SHA256, identity CONNECTOR_PSK_IDENTITY); the
 *            32-byte key is handed to the iPad over USB in MSG_PAIR.
 *
 * LAN discovery (UDP, host port CONNECTOR_PORT): the iPad broadcasts
 * "CNDQ"; the host answers "CNDR" + 8-byte host id + u16 TCP port.
 * host id = first 8 bytes of SHA-256(CONNECTOR_ID_SALT || key).
 */
#ifndef CONNECTOR_PROTOCOL_H
#define CONNECTOR_PROTOCOL_H

#define CONNECTOR_PORT 27183
#define CONNECTOR_HDR_LEN 5

#define CONNECTOR_KEY_LEN 32
#define CONNECTOR_ID_LEN 8
#define CONNECTOR_PSK_IDENTITY "connector"
#define CONNECTOR_ID_SALT "connector-id"
#define CONNECTOR_DISCOVER_QUERY "CNDQ"
#define CONNECTOR_DISCOVER_REPLY "CNDR"

enum {
    /* host -> iPad */
    MSG_CONFIG = 1,      /* u32 width, u32 height (pixels of the virtual display) */
    MSG_VIDEO = 2,       /* one H.264 access unit, Annex B */
    MSG_PAIR = 3,        /* USB only: u16 tcp port, key[CONNECTOR_KEY_LEN],
                            u8 n, host name[n], u8 m, internet address[m] ("" if none) */

    /* iPad -> host */
    MSG_HELLO = 16,      /* u32 width, u32 height (native screen pixels) */
    MSG_MOUSE_MOVE = 17, /* u16 x, u16 y, normalized 0..65535 */
    MSG_BUTTON = 18,     /* u8 button (1 left, 2 middle, 3 right), u8 pressed */
    MSG_SCROLL = 19,     /* i16 dx, i16 dy in wheel steps (dy > 0 scrolls down) */
    MSG_KEYFRAME = 20,   /* no payload: decoder lost sync, send an IDR */
    MSG_SETTINGS = 21,   /* u16 scale percent, u8 quality (0..2), u8 portrait,
                            u8 mirror (optional: 1 = show the main screen instead) */
    MSG_KEY = 22,        /* u32 X keysym, u8 modifiers (MOD_*): press and release */
    MSG_TEXT = 23,       /* UTF-8 text to type */
    MSG_MOUSE_REL = 24,  /* i16 dx, i16 dy in host pixels (trackpad mode) */
    MSG_APP_INFO = 25,   /* u32 unix time when the app's signature expires, 0 if unknown */
};

enum { MOD_SHIFT = 1, MOD_CTRL = 2, MOD_ALT = 4, MOD_SUPER = 8 };

/* Interface scale presets offered by the iPad app, percent of native pixels. */
#define CONNECTOR_SCALE_DEFAULT 125

#endif
