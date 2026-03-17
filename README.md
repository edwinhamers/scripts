# scripts

## ytdown.sh

A powerful macOS-friendly batch downloader for YouTube content using `yt-dlp` and `ffmpeg`.

This script supports:
- Audio download (MP3)
- Video download (best quality, merged to MP4)
- Parallel downloads
- Smart skipping of already downloaded content
- Clean, consistent filenames
- Optional extraction of recording dates from titles (strict rules)

### Features

- Batch processing from a `.txt` file (one URL per line)
- Parallel downloads for faster execution
- Automatic skip of already downloaded videos using archive files
- Clean filename formatting
- Supports:
  - `-audio`
  - `-video`
  - `-audiovideo`
Bash script that downloads the audio, video or both and the thumbnail from Youtube from a list of Youtube video links.

### Requirements and dependencies
Install with Homebrew:

```brew install yt-dlp ffmpeg bash python```

**Checks**
```
yt-dlp --version
ffmpeg -version
ffprobe -version
python3 --version
```

### Usage
```
- ./ytdown.sh -audio      links.txt [output_dir] [prefix] [parallel]
- ./ytdown.sh -video      links.txt [output_dir] [prefix] [parallel]
- ./ytdown.sh -audiovideo links.txt [output_dir] [prefix] [parallel]

Examples
- ./ytdown.sh -audio ytlinks.txt
- ./ytdown.sh -video ytlinks.txt "$HOME/Movies/KKS" "KKS" 3
- ./ytdown.sh -audiovideo ytlinks.txt "$HOME/Media/KKS" "KKS" 4
```

### Commandline options
**[prefix]** - prefix that gets added to the filename

**[parallel]** - Number of threads. 3-4 is recommended

### Filename Output
The script will try to create a logical filename that includes the prefix, recording date, title, location and other details when available. Here are some examples of generated titles:

- 2016-12-10_DOR_Initiation-Lecture-Eng-by-HH-Kadamba-Kanana-Swami-Maharaj-on-10th-Dec-2016-Melbourne-Australia_HARE-KRISHNA-MELBOURNE-ISKCON-TEMPLE.mp3

> **Note**
> - Special characters "(){}|,." will be removed from the title and replaced by -
> - Full video title will be included
> - recording date will be extracted if available and logical
> - recording location will be added when available

## Filename Format

[YYYY-MM-DD]_PREFIX_Title_Location.ext

Date only included if confidently extracted.

## Archive System

.downloaded_audio.txt
.downloaded_video.txt

Used to skip already downloaded videos.


## Parallel Downloads

Recommended:
- 3–4

---

