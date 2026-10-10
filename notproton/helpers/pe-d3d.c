// pe-d3d: reports which Direct3D runtimes a PE image links.
//
//   pe-d3d <file.exe|file.dll>...
//
// For each file prints one line "<flags> <path>", where flags is a comma list of
//   d3d12 d3d11 dxgi d3d10 d3d9 d3d8 ddraw opengl vulkan
// each suffixed with ":i" for a normal import or ":d" for a delay-load import, or "-" when
// none is found. Only the import and delay-import directories are read, never the strings,
// so an engine that merely carries the name of an optional renderer does not count.

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint32_t va, raw, vsize, rsize; } section_t;

typedef struct {
    const uint8_t *data;
    size_t size;
    section_t sec[96];
    int nsec;
} pe_t;

static uint16_t rd16(const pe_t *pe, size_t off) {
    return off + 2 <= pe->size ? (uint16_t)(pe->data[off] | pe->data[off + 1] << 8) : 0;
}

static uint32_t rd32(const pe_t *pe, size_t off) {
    return off + 4 <= pe->size ? (uint32_t)rd16(pe, off) | (uint32_t)rd16(pe, off + 2) << 16 : 0;
}

static int rva_to_off(const pe_t *pe, uint32_t rva, size_t *out) {
    for (int i = 0; i < pe->nsec; i++) {
        const section_t *s = &pe->sec[i];
        uint32_t span = s->vsize > s->rsize ? s->vsize : s->rsize;
        if (rva >= s->va && rva < s->va + span) {
            size_t off = (size_t)s->raw + (rva - s->va);
            if (off >= pe->size) return 0;
            *out = off;
            return 1;
        }
    }
    return 0;
}

static const char *const runtimes[] = {
    "d3d12", "d3d11", "dxgi", "d3d10", "d3d9", "d3d8", "ddraw", "opengl32", "vulkan-1",
};
#define NRT (sizeof(runtimes) / sizeof(runtimes[0]))

static void note(const pe_t *pe, uint32_t name_rva, char kind, char found[NRT]) {
    size_t off;
    char name[64];
    size_t n = 0;
    if (!rva_to_off(pe, name_rva, &off)) return;
    while (n + 1 < sizeof(name) && off + n < pe->size && pe->data[off + n]) {
        name[n] = (char)tolower(pe->data[off + n]);
        n++;
    }
    name[n] = 0;
    char *dot = strstr(name, ".dll");
    if (!dot) return;
    *dot = 0;
    // d3d10_1 and d3d10core count as d3d10
    if (!strncmp(name, "d3d10", 5)) name[5] = 0;
    for (size_t i = 0; i < NRT; i++)
        if (!strcmp(name, runtimes[i]) && (found[i] == 0 || kind == 'i')) found[i] = kind;
}

static void scan(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("? %s\n", path); return; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0x200 || len > (1L << 31)) { fclose(f); printf("- %s\n", path); return; }
    uint8_t *buf = malloc((size_t)len);
    if (!buf || fread(buf, 1, (size_t)len, f) != (size_t)len) { fclose(f); free(buf); printf("? %s\n", path); return; }
    fclose(f);

    pe_t pe = { .data = buf, .size = (size_t)len };
    char found[NRT] = { 0 };
    uint32_t e_lfanew = rd32(&pe, 0x3c);
    if (rd16(&pe, 0) != 0x5a4d || rd32(&pe, e_lfanew) != 0x00004550) goto out;

    size_t coff = e_lfanew + 4;
    int nsec = rd16(&pe, coff + 2);
    size_t opt = coff + 20;
    uint16_t optsize = rd16(&pe, coff + 16);
    uint16_t magic = rd16(&pe, opt);
    size_t dirs = opt + (magic == 0x20b ? 112 : 96);
    size_t sect = opt + optsize;
    pe.nsec = nsec > 96 ? 96 : nsec;
    for (int i = 0; i < pe.nsec; i++) {
        size_t s = sect + (size_t)i * 40;
        pe.sec[i] = (section_t){ rd32(&pe, s + 12), rd32(&pe, s + 20), rd32(&pe, s + 8), rd32(&pe, s + 16) };
    }

    size_t off;
    uint32_t imp = rd32(&pe, dirs + 8);          // IMAGE_DIRECTORY_ENTRY_IMPORT
    if (imp && rva_to_off(&pe, imp, &off))
        for (int i = 0; i < 4096; i++, off += 20) {
            uint32_t name = rd32(&pe, off + 12);
            if (!name && !rd32(&pe, off)) break;
            note(&pe, name, 'i', found);
        }
    uint32_t dly = rd32(&pe, dirs + 13 * 8);     // IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT
    if (dly && rva_to_off(&pe, dly, &off))
        for (int i = 0; i < 4096; i++, off += 32) {
            uint32_t attrs = rd32(&pe, off), name = rd32(&pe, off + 4);
            if (!name) break;
            // pre-VC7 delay descriptors hold VAs instead of RVAs
            if (!(attrs & 1)) {
                uint64_t base = magic == 0x20b ? (uint64_t)rd32(&pe, opt + 24) | (uint64_t)rd32(&pe, opt + 28) << 32
                                               : rd32(&pe, opt + 28);
                name = (uint32_t)(name - base);
            }
            note(&pe, name, 'd', found);
        }
out:
    {
        int any = 0;
        for (size_t i = 0; i < NRT; i++) {
            if (!found[i]) continue;
            const char *label = !strcmp(runtimes[i], "opengl32") ? "opengl"
                              : !strcmp(runtimes[i], "vulkan-1") ? "vulkan" : runtimes[i];
            printf("%s%s:%c", any ? "," : "", label, found[i]);
            any = 1;
        }
        printf("%s %s\n", any ? "" : "-", path);
    }
    free(buf);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: pe-d3d <pe-file>...\n"); return 2; }
    for (int i = 1; i < argc; i++) scan(argv[i]);
    return 0;
}
