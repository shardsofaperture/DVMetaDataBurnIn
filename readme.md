# DVMetaDataBurnIn

**DVMetaDataBurnIn** is a free, open source macOS utility for burning original DV/Digital8 camcorder date/time metadata directly into your video files. It’s powered by `dvrescue` and `ffmpeg`, which prior to this involvd me banging my head running temrinal scripts to get the same result. I wanted a beter way for myself outside of apple script. This is my attempt to make DV timestamp burning actually useable for batchwork. 
---

## Known Issues
- No log output sometimes - possibly due to file size or the time it takes for dvrescue to read the metadata
- No progress bar (just says running)
- No way to tell it where to save the file (it saves in the same location as the original file)
- May make splash screen shorter, I just wanted one like the old Sony software had
- Still trying to figure out if large files hang this or not
- File chooser doesn't limit to file types
- Having SOME issues with large files and dvrescue but working on it
- Clips that have muliple date/times for start stop only count forward from the first read timecode as of right now. So if you have a video clip manually captured that was 5 minutes at 2pm, and 5 minutes at 3pm, the timecode will run from 2:00 - 2:10 not 2:00-2:05 then jump to 3:00 to 3:05 in the burn. Will fix later.
- Unknown issue - will this work on M series macs? IDK Using an intel mac.

---

## Change Log

--- 11/30/25
* Added passthrough (convert-only) mode alongside burn-in mode.

* Added missing-metadata behavior options: stop with error, convert without burn-in, or skip file.

* Updated dvmetaburn.zsh to: Parse full dvrescue JSON instead of only the first frame, detect the first valid rdt anywhere in the file and fall back based on --missing-meta= instead of crashing.

* Support --burn-mode=passthrough for no-metadata conversions.

* Added added BurnMode and MissingMetaMode with UI controls for so its now possible to burn-in  text OR convert-only, and changed how missing-metadata behavior is handled (i.e. hopefully won't just crash now)

* Made log selectablew

* Added DVRESCUE debug function (to check to see if metadata is missing or any other issues)

* Added stop and clear log button, as well as made log copyable instead of view only and some other debug stuff


## Features (work in progress but already functional)

- Batch or single-file AVI processing  
- Extracts original camcorder recording date/time from embedded DV metadata  
- Overlay date/time using what I feel are camcorder-style fonts   
- Export to MOV (original quality) or MP4 (H.264) but trying to keep it as close to "DV visual style" as possible (low compression) 
- No command-line required — simple macOS UI (thank god) 

---

## Features (future maybe)
- Font drop down selector
- Pasthough to just convert from AVI1 to mp4 for sharing to modern devices
- Additional layouts for how the camcorder fonts are burned in
- Ability to save as containerized video w/ subtitles rather than burnin as an option.



---

## Usage

1. **Download** the app (no releases yet — still iterating).  
2. **Launch** it.  
2a. Tell apple you don't care about security becuase you got this from the internet.'
3. **Select** a file or an entire folder of DV/Digital8 clips.  
4. Pick your **layout** and **output format**.  
5. Hit **Run Burn-In** and let it cook.

---

## Requirements

Nothing external.  
`ffmpeg` and `dvrescue` are bundled in the app bundle according to their respective licenses.  
Full license texts are in:  
`Resources/licenses/`

---

## Building (if you want to build it yourself)

1. Clone the repo:
    ```bash
    git clone https://github.com/yourname/DVMetaDataBurnIn.git
    ```
2. Open `DVMetaDataBurnIn.xcodeproj` in Xcode.  
3. Build & run.

Bundled tools:
- FFmpeg (LGPL/GPL)  
- dvrescue (BSD-3-Clause)

---

## Credits

- App & UI: Zach Zarzycki (powered by a suspicious amount of late-night vibe-coding)  

- **UAV OSD Font** by Nicholas Kruse  
  - Free for personal and commercial use  
  - https://www.dafont.com/uav-osd.font  
  - https://nicholaskruse.com/work/uavosd  

- **VCR OSD Mono** by Riciery Leal (mrmanet)  
  - Free for personal and commercial use per author comments  
  - https://www.dafont.com/font-comment.php?file=vcr_osd_mono  

- **FFmpeg** — https://ffmpeg.org/  
- **dvrescue** — https://mediaarea.net/DVRescue  

---

## License

MIT License (see [LICENSE](LICENSE))
