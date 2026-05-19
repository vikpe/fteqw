// SPDX-License-Identifier: 0BSD

// Hub-specific web/GL helpers. Currently a single function -
// Hub_CaptureBackbuffer - used by the QTV stream-switch transition
// flow to snapshot the current backbuffer before disconnect tears
// the live scene down. Lives alongside the other cl_hub_*.c files
// so all hub-fork additions sit together in engine/client/.

#include "quakedef.h"

#ifdef GLQUAKE

#include "glquake.h"
#include "shader.h"

// Copies the current backbuffer into the named render-target texture.
// Called from CL_QTVPlay_f so the last live frame is preserved before
// the qtv stream switch tears down state. The transition addon
// (hub_addon) samples this texture by name via VF_RT_SOURCECOLOUR.
// IF_NOPURGE keeps the texture alive across the CL_MakeActive ->
// Image_Purge cycle so the melt overlay can still find it after the
// new world has loaded.
void Hub_CaptureBackbuffer(const char *texname)
{
	texid_t tex;
	unsigned int flags;
	if (!texname || !*texname)
		return;
	if (vid.pixelwidth <= 0 || vid.pixelheight <= 0)
		return;
	flags = IF_NOMIPMAP | IF_CLAMP | IF_LINEAR | IF_RENDERTARGET | IF_NOPURGE;
	// Register the texture in the image pool by name (no storage yet
	// - rtfmt = TF_INVALID skips Image_Upload). CSQC binds the same
	// name via VF_RT_SOURCECOLOUR so the melt shader's $sourcecolour
	// resolves to this texture.
	tex = R2D_RT_Configure(texname, 0, 0, TF_INVALID, flags);
	if (!TEXVALID(tex))
		return;
	tex->flags  |= IF_NOPURGE;
	tex->width   = vid.pixelwidth;
	tex->height  = vid.pixelheight;
	tex->format  = PTI_RGB8;
	// Mark as loaded so the texture-loader doesn't try to fetch this
	// name from disk (it isn't a file resource).
	tex->status  = TEX_LOADED;
	// First-time setup: Image_CreateTexture allocates the image_t but
	// not the GL texture name. The shadowmap path does the same gen
	// (gl_backend.c:1100). Subsequent captures reuse the existing
	// texture object.
	if (!tex->num)
		qglGenTextures(1, &tex->num);
	GL_MTBind(0, GL_TEXTURE_2D, tex);
	// Allocate storage AND copy backbuffer in one call. GL_RGB matches
	// the default WebGL canvas color format (no alpha) - using GL_RGBA
	// or going through Image_Upload's sized formats triggers
	// "GL_INVALID_OPERATION: Invalid copy texture format combination".
	// Pattern mirrors motion blur (engine/gl/gl_rmain.c:1646).
	qglCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 0, 0,
	                  vid.pixelwidth, vid.pixelheight, 0);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

#else

void Hub_CaptureBackbuffer(const char *texname)
{
	(void)texname;
}

#endif
