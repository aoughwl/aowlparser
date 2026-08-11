/* jsonfast_simd.c — the two byte-consuming loops, sixteen bytes at a time.
 *
 * jsonfast is otherwise pure nimony. These two functions are not, for one
 * reason: nimony cannot take the address of a string's bytes (`addr s[i]` is
 * rejected), so the word-at-a-time and SIMD tricks that separate a good scalar
 * JSON parser from simdjson are not expressible in the language today. That is
 * a nimony gap, filed as an aowlsem requirement, not a design choice.
 *
 * Both functions are pure scanners: they find the next INTERESTING byte and
 * return its offset. Every decision — what the byte means, whether it is an
 * error, what goes on the tape — stays in jsonfast.nim, so this file cannot
 * disagree with the parser about the grammar. It can only be wrong about where
 * the next `"` is, and the CPython gate (10,029 files, 494k prefixes) would say
 * so immediately.
 *
 * SSE2 is baseline on x86-64, so the vector path needs no runtime check. On any
 * other architecture the scalar fallback compiles instead and is still correct.
 */

#include <stddef.h>
#include <stdint.h>

#if defined(__SSE2__) || defined(_M_X64) || defined(__x86_64__)
#define JF_SSE2 1
#include <emmintrin.h>
#endif

/* Offset of the first byte that is NOT space, tab, newline or carriage return. */
size_t jf_skip_ws(const char *s, size_t n, size_t i) {
#ifdef JF_SSE2
  const __m128i sp = _mm_set1_epi8(' ');
  const __m128i tab = _mm_set1_epi8('\t');
  const __m128i nl = _mm_set1_epi8('\n');
  const __m128i cr = _mm_set1_epi8('\r');
  while (i + 16 <= n) {
    __m128i v = _mm_loadu_si128((const __m128i *)(s + i));
    __m128i ws = _mm_or_si128(
        _mm_or_si128(_mm_cmpeq_epi8(v, sp), _mm_cmpeq_epi8(v, tab)),
        _mm_or_si128(_mm_cmpeq_epi8(v, nl), _mm_cmpeq_epi8(v, cr)));
    /* A 1 bit per whitespace byte. The first 0 is the first non-whitespace. */
    unsigned mask = (unsigned)_mm_movemask_epi8(ws);
    if (mask != 0xFFFFu) return i + (size_t)__builtin_ctz(~mask & 0xFFFFu);
    i += 16;
  }
#endif
  while (i < n) {
    char c = s[i];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
    i++;
  }
  return i;
}

/* Offset of the first byte that can end a JSON string body: the closing quote,
 * a backslash, or a control character (< 0x20, which RFC 8259 forbids raw).
 * Returns n if the input runs out first — an unterminated string, which the
 * caller diagnoses. */
size_t jf_scan_string(const char *s, size_t n, size_t i) {
#ifdef JF_SSE2
  const __m128i quote = _mm_set1_epi8('"');
  const __m128i bslash = _mm_set1_epi8('\\');
  /* c < 0x20 unsigned  <=>  (c ^ 0x80) < (0x20 ^ 0x80) signed, which is what
   * _mm_cmplt_epi8 gives us after biasing both sides. */
  const __m128i bias = _mm_set1_epi8((char)0x80);
  const __m128i ctl = _mm_set1_epi8((char)(0x20 ^ 0x80));
  while (i + 16 <= n) {
    __m128i v = _mm_loadu_si128((const __m128i *)(s + i));
    __m128i stop = _mm_or_si128(
        _mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, bslash)),
        _mm_cmplt_epi8(_mm_xor_si128(v, bias), ctl));
    unsigned mask = (unsigned)_mm_movemask_epi8(stop);
    if (mask != 0) return i + (size_t)__builtin_ctz(mask);
    i += 16;
  }
#endif
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    if (c == '"' || c == '\\' || c < 0x20) break;
    i++;
  }
  return i;
}
