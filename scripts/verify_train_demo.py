#!/usr/bin/env python3
"""Read-only, opt-in media measurements. Requires explicit paths and existing tools.

Reports JSON to stdout; never downloads media or writes beside inputs. Hashes
concatenated encoded video payload bytes (not packet hashes) for DV comparisons.
Exit 1 means a decode/probe/manifest/identity check failed; unknown is not success.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def run(argv):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def sha_file(path):
    h = hashlib.sha256()
    with path.open('rb') as src:
        for block in iter(lambda: src.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def stream_hash(argv):
    # FFmpeg errors go to a temporary file so neither pipe can deadlock.
    import tempfile
    h = hashlib.sha256()
    size = 0
    with tempfile.TemporaryFile() as err:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=err)
        for block in iter(lambda: p.stdout.read(1024 * 1024), b''):
            size += len(block)
            h.update(block)
        p.stdout.close()
        code = p.wait()
        err.seek(0)
        error = err.read().decode(errors='replace')
    if code or error.strip():
        raise RuntimeError(f'stream hash failed (exit {code}): {error}')
    return {'bytes': size, 'sha256': h.hexdigest()}


def measure(path, ffmpeg, ffprobe, dvrescue=None):
    before = sha_file(path)
    p = run([ffprobe, '-v', 'error', '-count_frames', '-show_format', '-show_streams', '-of', 'json', str(path)])
    if p.returncode or p.stderr.strip():
        raise RuntimeError(p.stderr.decode(errors='replace'))
    probe = json.loads(p.stdout)
    probe['format'].pop('filename', None)
    for kind in ('video', 'audio', 'subtitle'):
        if sum(s['codec_type'] == kind for s in probe['streams']) > 1:
            raise RuntimeError(f'multiple {kind} streams are unsupported; select a single-track fixture')
    # Do not export arbitrary container metadata that could identify local users.
    for stream in probe['streams']:
        stream['tags'] = {k:v for k,v in stream.get('tags', {}).items() if k in ('encoder','language','title','handler_name','name')}
    probe['format']['tags'] = {k:v for k,v in probe['format'].get('tags', {}).items() if k in ('encoder','major_brand','minor_version','compatible_brands')}
    p = run([ffmpeg, '-nostdin', '-v', 'error', '-i', str(path), '-map', '0:v?', '-map', '0:a?', '-f', 'null', '-'])
    decode = {'exit_code': p.returncode, 'stderr': p.stderr.decode(errors='replace').replace(str(path), path.name)}
    result = {'filename': path.name, 'bytes': path.stat().st_size, 'sha256': before, 'probe': probe,
              'decode': decode, 'decode_ok': p.returncode == 0 and not p.stderr.strip()}
    videos = [s for s in probe['streams'] if s['codec_type'] == 'video']
    if videos and videos[0]['codec_name'] == 'dvvideo':
        result['encoded_dv_payload'] = stream_hash([ffmpeg, '-nostdin', '-v', 'error', '-i', str(path), '-map', '0:v:0', '-c:v', 'copy', '-f', 'data', '-'])
    if any(s['codec_type'] == 'audio' for s in probe['streams']):
        result['decoded_audio_s16le'] = stream_hash([ffmpeg, '-nostdin', '-v', 'error', '-i', str(path), '-map', '0:a:0', '-c:a', 'pcm_s16le', '-f', 's16le', '-'])
    if videos:
        p = run([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_frames', '-show_entries', 'frame=interlaced_frame,top_field_first', '-of', 'json', str(path)])
        if p.returncode or p.stderr.strip(): raise RuntimeError('frame probe failed')
        frames = json.loads(p.stdout)['frames']
        result['decoded_field_flags'] = {'frames':len(frames), 'interlaced':sum(f.get('interlaced_frame',0) for f in frames), 'top_first':sum(f.get('top_field_first',0) for f in frames)}
    if dvrescue and videos and videos[0]['codec_name'] == 'dvvideo':
        p = run([dvrescue, str(path)])
        if p.returncode: raise RuntimeError('DVRescue failed')
        records = []
        for line in (p.stdout + b'\n' + p.stderr).decode(errors='replace').splitlines():
            m = re.match(r'\s*(\d+)\s+(\S+)\s+(\d{4}-\d\d-\d\d)\s+(\d\d:\d\d:\d\d)', line)
            if m: records.append({'frame':int(m[1])-1, 'timecode':m[2], 'recording_datetime':m[3]+' '+m[4]})
        if not records: raise RuntimeError('DVRescue returned no recording-date rows')
        transitions = [r for i,r in enumerate(records) if not i or r['recording_datetime'] != records[i-1]['recording_datetime']]
        result['recording_metadata'] = {'records':len(records), 'transitions':transitions, 'last':records[-1] if records else None}
    p = run([ffprobe, '-v', 'error', '-show_packets', '-show_entries', 'packet=codec_type,pts_time,duration_time', '-of', 'json', str(path)])
    if p.returncode or p.stderr.strip(): raise RuntimeError('packet probe failed')
    packets = json.loads(p.stdout)['packets']
    result['packet_timing'] = {}
    for kind in ('video', 'audio', 'subtitle'):
        selected = [p for p in packets if p['codec_type'] == kind and 'pts_time' in p]
        if selected:
            result['packet_timing'][kind] = {'count':len(selected), 'first_pts':min(float(p['pts_time']) for p in selected), 'end_pts':max(float(p['pts_time']) + float(p.get('duration_time',0)) for p in selected)}
        if kind == 'subtitle' and selected:
            intervals = sorted([[float(p['pts_time']),float(p['pts_time'])+float(p.get('duration_time',0))] for p in selected])
            result['subtitle_intervals'] = intervals
            result['subtitle_intervals_valid'] = all(a < b for a,b in intervals) and all(intervals[i][0] >= intervals[i-1][1]-1e-9 for i in range(1,len(intervals)))
            video = result['packet_timing'].get('video', {})
            result['subtitle_covers_video'] = bool(video) and intervals[0][0] <= video['first_pts'] and intervals[-1][1] >= video['end_pts'] and all(abs(intervals[i][0]-intervals[i-1][1]) < 1e-9 for i in range(1,len(intervals)))
    result['input_unchanged'] = sha_file(path) == before
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--ffmpeg', default='ffmpeg')
    ap.add_argument('--ffprobe', default='ffprobe')
    ap.add_argument('--dvrescue')
    ap.add_argument('--manifest', type=Path, help='Check each input against a hash-pinned manifest sample filename')
    ap.add_argument('--reference', type=Path, help='Compare DV payload and decoded PCM audio to this explicit reference')
    ap.add_argument('files', type=Path, nargs='+')
    args = ap.parse_args()
    report = {'schema_version':1, 'method':'Read-only full decode; DV concatenated encoded payload; first audio stream decoded to native-rate/channel s16le', 'tools':{}, 'files':[], 'errors':[]}
    for key,tool in [('ffmpeg',args.ffmpeg),('ffprobe',args.ffprobe),('dvrescue',args.dvrescue)]:
        if tool:
            try:
                p = run([tool, '--version' if key == 'dvrescue' else '-version'])
                if p.returncode: raise RuntimeError('version command failed')
                report['tools'][key] = (p.stdout or p.stderr).decode(errors='replace').splitlines()[0]
            except Exception as e: report['errors'].append(f'{key}: {e}')
    try:
        expected = {s['filename']:s for s in json.loads(args.manifest.read_text())['samples']} if args.manifest else None
        reference = measure(args.reference.resolve(strict=True), args.ffmpeg, args.ffprobe, args.dvrescue) if args.reference else None
        if reference and (not reference['decode_ok'] or not reference['input_unchanged']): report['errors'].append('reference decode or preservation failed')
        for file in args.files:
            result = measure(file.resolve(strict=True), args.ffmpeg, args.ffprobe, args.dvrescue)
            if expected is not None:
                item = expected.get(file.name)
                result['manifest_match'] = bool(item and result['sha256'] == item['sha256'] and result['bytes'] == item['bytes'])
                if not result['manifest_match']: report['errors'].append(f'{file.name}: manifest mismatch')
            if reference and 'encoded_dv_payload' in result:
                result['reference_dv_payload_equal'] = result['encoded_dv_payload'] == reference.get('encoded_dv_payload')
                audio = next((s for s in result['probe']['streams'] if s['codec_type'] == 'audio'), None)
                ref_audio = next((s for s in reference['probe']['streams'] if s['codec_type'] == 'audio'), None)
                result['reference_decoded_audio_equal'] = bool(audio and ref_audio and result.get('decoded_audio_s16le') and reference.get('decoded_audio_s16le')) and all(audio.get(k) == ref_audio.get(k) for k in ('sample_rate','channels')) and result['decoded_audio_s16le'] == reference['decoded_audio_s16le']
                result['reference_audio_layout_equal'] = (audio['channel_layout'] == ref_audio['channel_layout']) if audio and ref_audio and audio.get('channel_layout') and ref_audio.get('channel_layout') else None
                if not result['reference_dv_payload_equal'] or not result['reference_decoded_audio_equal']: report['errors'].append(f'{file.name}: reference identity mismatch')
            if result.get('subtitle_intervals_valid') is False or result.get('subtitle_covers_video') is False: report['errors'].append(f'{file.name}: subtitle interval or coverage failure')
            report['files'].append(result)
            if not result['decode_ok'] or not result['input_unchanged']: report['errors'].append(f'{file.name}: decode or preservation failed')
    except Exception as e:
        report['errors'].append(str(e))
    print(json.dumps(report, indent=2))
    return bool(report['errors'])


if __name__ == '__main__':
    sys.exit(main())
