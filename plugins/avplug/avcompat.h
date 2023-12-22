#ifndef AVCOMPAT_H
#define AVCOMPAT_H

#include <libavcodec/version.h>

#if LIBAVCODEC_VERSION_INT < AV_VERSION_INT(59, 37, 100)
#define AVCOMPAT_CTX_GET_CHANNELS(c) (c->channels)
#define AVCOMPAT_CTX_SET_CHANNELS(c, chn) { c->channels = chn; }
#else
#define AVCOMPAT_CTX_GET_CHANNELS(c) (c->ch_layout.nb_channels)
#define AVCOMPAT_CTX_SET_CHANNELS(c, chn) { c->ch_layout.nb_channels = chn; }
#endif

#endif