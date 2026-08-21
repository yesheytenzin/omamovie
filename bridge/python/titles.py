"""Port of providers/moviebox/title.rs"""
def clean_moviebox_title(raw_title: str) -> str:
    title = raw_title.strip()
    if not title:
        return ""

    # Strip leading [..] blocks repeatedly
    while title.startswith("["):
        close = title.find("]")
        if close != -1:
            remainder = title[close + 1:].strip()
            if remainder:
                title = remainder
            else:
                break
        else:
            break

    # trailing [..]
    pos = title.find("[")
    if pos != -1 and pos > 0:
        title = title[:pos].strip()

    # ( ... ) handling - keep year if inside is year, else strip
    pos = title.find("(")
    if pos != -1 and pos > 0:
        inside = title[pos + 1:]
        inside_content = inside.split(")", 1)[0].strip() if ")" in inside else ""
        is_year = False
        if len(inside_content) == 4 and inside_content.isdigit():
            try:
                y = int(inside_content)
                if 1900 <= y <= 2099:
                    is_year = True
            except:
                pass
        if not is_year:
            title = title[:pos].strip()

    # " - " suffix language/tag stripping
    pos = title.rfind(" - ")
    if pos != -1:
        suffix = title[pos + 3:].lower()
        tags = ["hindi","tamil","telugu","kannada","malayalam","bengali","marathi","punjabi","gujarati","urdu","english","spanish","french","german","italian","japanese","korean","chinese","russian","portuguese","turkish","arabic","dub","audio","multi","season"]
        is_tag = any(t in suffix for t in tags)
        if not is_tag:
            # check S01 style
            if suffix.startswith("s") and len(suffix) > 1 and all(c.isdigit() or c == "-" for c in suffix[1:]):
                is_tag = True
        if is_tag:
            title = title[:pos].strip()

    # S01 suffix
    pos = title.rfind(" S")
    if pos != -1:
        suffix = title[pos+2:]
        if suffix and suffix[0].isdigit() and all(c.isdigit() or c in "-S" for c in suffix):
            title = title[:pos].strip()

    # " season "
    lower = title.lower()
    pos = lower.rfind(" season ")
    if pos != -1:
        title = title[:pos].strip()

    cleaned = title.strip("".join(["-"," ",":","_",".", " "])).strip()
    # Rust does trim_end_matches(['-'.':'.'_' '.' ' ']).trim()
    # Mimic: rstrip chars -:_.
    # Actually Rust: trim_end_matches(['-'.':'.'_' '.' ' ']).trim()
    # We'll do rstrip then strip again (already)
    # Do exact: while end char in set, remove
    while cleaned and cleaned[-1] in "-:_. ":
        cleaned = cleaned[:-1].strip()
    if not cleaned:
        return raw_title.strip()
    return cleaned

def clean_title(raw: str) -> str:
    # bridge/src/main.rs clean_title splits on '[' and takes first
    # but titles.py is more complete. Keep simple for search normalization? use clean_moviebox_title for consistency?
    # main.rs uses: raw.split('[').next().trim()
    # We'll expose both.
    return raw.split("[")[0].strip() if raw else ""

def language_to_code(name: str):
    lower = name.strip().lower()
    mapping = {
        "english": "en", "en": "en", "eng": "en",
        "spanish": "es", "es": "es", "spa": "es", "español": "es", "castellano": "es",
        "hindi": "hi", "hi": "hi", "hin": "hi",
        "french": "fr", "fr": "fr", "fre": "fr", "fra": "fr", "français": "fr",
        "german": "de", "de": "de", "ger": "de", "deu": "de", "deutsch": "de",
        "italian": "it", "it": "it", "ita": "it", "italiano": "it",
        "japanese": "ja", "ja": "ja", "jpn": "ja", "日本語": "ja",
        "korean": "ko", "ko": "ko", "kor": "ko", "한국어": "ko",
        "chinese": "zh", "zh": "zh", "zho": "zh", "chi": "zh", "中文": "zh", "mandarin": "zh", "cantonese": "zh",
        "portuguese": "pt", "pt": "pt", "por": "pt", "português": "pt",
        "russian": "ru", "ru": "ru", "rus": "ru", "русский": "ru",
        "arabic": "ar", "ar": "ar", "ara": "ar", "العربية": "ar",
        "turkish": "tr", "tr": "tr", "tur": "tr", "türkçe": "tr",
        "bengali": "bn", "bn": "bn", "ben": "bn", "বাংলা": "bn",
        "tamil": "ta", "ta": "ta", "tam": "ta", "தமிழ்": "ta",
        "telugu": "te", "te": "te", "tel": "te", "తెలుగు": "te",
        "malayalam": "ml", "ml": "ml", "mal": "ml", "മലയാളം": "ml",
        "kannada": "kn", "kn": "kn", "kan": "kn", "ಕನ್ನಡ": "kn",
        "marathi": "mr", "mr": "mr", "mar": "mr", "मराठी": "mr",
        "punjabi": "pa", "pa": "pa", "pan": "pa", "ਪੰਜਾਬੀ": "pa",
        "gujarati": "gu", "gu": "gu", "guj": "gu", "ગુજરાતી": "gu",
        "urdu": "ur", "ur": "ur", "urd": "ur", "اردو": "ur",
        "indonesian": "id", "id": "id", "ind": "id", "bahasa": "id",
        "thai": "th", "th": "th", "tha": "th", "ไทย": "th",
        "vietnamese": "vi", "vi": "vi", "vie": "vi", "tiếng việt": "vi",
        "dutch": "nl", "nl": "nl", "dut": "nl", "nld": "nl", "nederlands": "nl",
        "polish": "pl", "pl": "pl", "pol": "pl", "polski": "pl",
        "swedish": "sv", "sv": "sv", "swe": "sv", "svenska": "sv",
        "danish": "da", "da": "da", "dan": "da", "dansk": "da",
        "norwegian": "no", "no": "no", "nor": "no", "norsk": "no",
        "finnish": "fi", "fi": "fi", "fin": "fi", "suomi": "fi",
        "greek": "el", "el": "el", "ell": "el", "gre": "el", "ελληνικά": "el",
        "hebrew": "he", "he": "he", "heb": "he", "עברית": "he",
        "czech": "cs", "cs": "cs", "cze": "cs", "ces": "cs", "čeština": "cs",
        "hungarian": "hu", "hu": "hu", "hun": "hu", "magyar": "hu",
        "romanian": "ro", "ro": "ro", "rum": "ro", "ron": "ro", "română": "ro",
        "ukrainian": "uk", "uk": "uk", "ukr": "uk", "українська": "uk",
        "persian": "fa", "fa": "fa", "fas": "fa", "per": "fa", "فارسی": "fa",
        "tagalog": "tl", "tl": "tl", "fil": "tl", "filipino": "tl",
        "malay": "ms", "ms": "ms", "msa": "ms", "may": "ms", "melayu": "ms",
    }
    return mapping.get(lower)
