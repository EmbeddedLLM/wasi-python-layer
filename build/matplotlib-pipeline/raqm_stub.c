/*
 * raqm_stub.c — Minimal raqm implementation for WASI code interpreter.
 * Simple LTR glyph-by-glyph layout using FreeType directly.
 * No complex shaping (harfbuzz), no bidi (sheenbidi).
 * Sufficient for ASCII/Latin plot labels in matplotlib.
 */

#include <stdlib.h>
#include <string.h>
#include "raqm.h"

#define MAX_GLYPHS 4096
#define MAX_FACES 64

typedef struct {
    FT_Face face;
    size_t start;
    size_t len;
} face_range_t;

struct _raqm {
    uint32_t *text;
    size_t text_len;
    FT_Face default_face;
    FT_Int32 load_flags;
    raqm_glyph_t glyphs[MAX_GLYPHS];
    size_t num_glyphs;
    face_range_t ranges[MAX_FACES];
    size_t num_ranges;
};

RAQM_API raqm_t *
raqm_create(void)
{
    return calloc(1, sizeof(raqm_t));
}

RAQM_API void
raqm_destroy(raqm_t *rq)
{
    if (rq) { free(rq->text); free(rq); }
}

RAQM_API void
raqm_clear_contents(raqm_t *rq)
{
    if (!rq) return;
    rq->num_glyphs = 0;
    rq->num_ranges = 0;
    free(rq->text);
    rq->text = NULL;
    rq->text_len = 0;
}

RAQM_API bool
raqm_set_text(raqm_t *rq, const uint32_t *text, size_t len)
{
    if (!rq || !text) return false;
    free(rq->text);
    rq->text = malloc(len * sizeof(uint32_t));
    if (!rq->text) return false;
    memcpy(rq->text, text, len * sizeof(uint32_t));
    rq->text_len = len;
    return true;
}

RAQM_API bool
raqm_set_freetype_face(raqm_t *rq, FT_Face face)
{
    if (!rq) return false;
    rq->default_face = face;
    return true;
}

RAQM_API bool
raqm_set_freetype_face_range(raqm_t *rq, FT_Face face, size_t start, size_t len)
{
    if (!rq || rq->num_ranges >= MAX_FACES) return false;
    rq->ranges[rq->num_ranges].face = face;
    rq->ranges[rq->num_ranges].start = start;
    rq->ranges[rq->num_ranges].len = len;
    rq->num_ranges++;
    return true;
}

RAQM_API bool
raqm_set_freetype_load_flags(raqm_t *rq, int flags)
{
    if (!rq) return false;
    rq->load_flags = flags;
    return true;
}

RAQM_API bool
raqm_add_font_feature(raqm_t *rq, const char *feature, int len)
{
    (void)rq; (void)feature; (void)len;
    return true;
}

RAQM_API bool
raqm_set_language(raqm_t *rq, const char *lang, size_t start, size_t len)
{
    (void)rq; (void)lang; (void)start; (void)len;
    return true;
}

RAQM_API bool
raqm_set_par_direction(raqm_t *rq, raqm_direction_t dir)
{
    (void)rq; (void)dir;
    return true;
}

static FT_Face
face_for_cluster(raqm_t *rq, size_t cluster)
{
    for (size_t i = 0; i < rq->num_ranges; i++) {
        if (cluster >= rq->ranges[i].start &&
            cluster < rq->ranges[i].start + rq->ranges[i].len) {
            return rq->ranges[i].face;
        }
    }
    return rq->default_face;
}

RAQM_API bool
raqm_layout(raqm_t *rq)
{
    if (!rq || !rq->default_face) return false;

    rq->num_glyphs = 0;

    for (size_t i = 0; i < rq->text_len && rq->num_glyphs < MAX_GLYPHS; i++) {
        FT_Face face = face_for_cluster(rq, i);
        if (!face) face = rq->default_face;

        FT_UInt glyph_index = FT_Get_Char_Index(face, rq->text[i]);
        if (FT_Load_Glyph(face, glyph_index, rq->load_flags) != 0) {
            glyph_index = 0;
            FT_Load_Glyph(face, 0, rq->load_flags);
        }

        raqm_glyph_t *g = &rq->glyphs[rq->num_glyphs];
        g->index = glyph_index;
        g->x_advance = (int)face->glyph->advance.x;
        g->y_advance = (int)face->glyph->advance.y;
        g->x_offset = 0;
        g->y_offset = 0;
        g->cluster = (uint32_t)i;
        g->ftface = face;
        rq->num_glyphs++;
    }

    return true;
}

RAQM_API raqm_glyph_t *
raqm_get_glyphs(raqm_t *rq, size_t *length)
{
    if (!rq) { if (length) *length = 0; return NULL; }
    if (length) *length = rq->num_glyphs;
    return rq->glyphs;
}

RAQM_API const char *
raqm_version_string(void)
{
    return RAQM_VERSION_STRING;
}
