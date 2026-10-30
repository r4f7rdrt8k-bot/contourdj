#ifndef CDJ_CORE_H
#define CDJ_CORE_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CDJEngine CDJEngine;
CDJEngine *cdj_create(double output_sample_rate);
/* Stop the audio callback before destroying the engine. */
void cdj_destroy(CDJEngine *engine);
/* Copies interleaved stereo on the control thread. False: invalid input/budget.
   One render caller; controls/load may run concurrently with that caller. */
bool cdj_load(CDJEngine *, int deck, const float *stereo, uint64_t frames, double sample_rate);
void cdj_render(CDJEngine *, float *left, float *right, uint32_t frames);
void cdj_play(CDJEngine *, int deck, bool playing);
bool cdj_is_playing(CDJEngine *, int deck);
void cdj_seek(CDJEngine *, int deck, double seconds);
double cdj_position(CDJEngine *, int deck);
void cdj_rate(CDJEngine *, int deck, double rate);
void cdj_volume(CDJEngine *, int deck, double volume);
void cdj_eq(CDJEngine *, int deck, double low_db, double mid_db, double high_db);
void cdj_filter(CDJEngine *, int deck, double value);
void cdj_effect(CDJEngine *, int deck, int kind, double mix);
void cdj_crossfader(CDJEngine *, double value);
void cdj_master(CDJEngine *, double volume);
void cdj_loop(CDJEngine *, int deck, double start_seconds, double end_seconds, bool enabled);
void cdj_reverse(CDJEngine *, int deck, bool enabled);
void cdj_pattern(CDJEngine *, bool enabled, double bpm, double volume);
float cdj_peak(CDJEngine *);
/* Optional bounded SPSC stereo recording ring. Begin/end/drain are control/
   writer-thread operations. Render is its only producer; drain its only reader.
   Ring overflow increments dropped frames instead of blocking the callback. */
bool cdj_record_begin(CDJEngine *);
void cdj_record_end(CDJEngine *);
uint32_t cdj_record_drain(CDJEngine *, float *stereo, uint32_t max_frames);
uint64_t cdj_record_dropped(CDJEngine *);
/* Reclaims retired tracks only on this non-render thread; safe during playback. */
void cdj_reclaim(CDJEngine *);
#ifdef __cplusplus
}
#endif
#endif
