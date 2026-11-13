#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""五语种资源体检(硬规矩 5 的"改完用脚本体检一遍")。

只查三件事,都是曾经真踩过的形态:
  1. 键集相等 —— 少一条就会回落到基础语言(Android/Harmony 是简中,Apple 是代码里的简中键名),
     界面上表现为"这一条没翻译",编译不报错。
  2. 繁体文件里出现简体独有字 —— 历史上 zh-Hant / zh_TW 曾整段是简体。
  3. 非中文语言里出现汉字 —— 历史上有过 es/fr 整段照抄英文;汉字则是抄串了文件
     (允许:备案号、品牌名)。

刻意**不做**的事:
  - 不做"值是否等于英文"的判据:Anime / Bilibili / Hong Kong / Auto / Version 这类同形词
    在 es/fr 里本来就该一样,拿它当判据只会制造误报(见 TROUBLESHOOTING H1589 一带的教训)。
  - 不检查 macOS 与 iOS 两套 .strings 的键是否彼此相等:iOS 有自己的 57 个界面键,是设计如此。

用法:
    python3 tools/check-l10n.py            # 全量;有问题退出 1
    python3 tools/check-l10n.py -v         # 另外打印 es/fr 与英文同形的键(仅供人看)
"""

import json
import re
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 只收"繁体里绝不该出现"的简体独有字。共用字(目/前/面/作…)混进来会制造误报,
# 历史那版体检就栽在这上面(TROUBLESHOOTING H1589)。
SIMPLIFIED_ONLY = set("这说门关页视简机网络时间听见来过对个务户读写图们为与从还进发")

ANDROID = [
    ("base", "android/app/src/main/res/values/strings.xml"),
    ("en", "android/app/src/main/res/values-en/strings.xml"),
    ("es", "android/app/src/main/res/values-es/strings.xml"),
    ("fr", "android/app/src/main/res/values-fr/strings.xml"),
    ("zh-rTW", "android/app/src/main/res/values-zh-rTW/strings.xml"),
]
HARMONY = [
    ("base", "harmony/entry/src/main/resources/base/element/string.json"),
    ("en_US", "harmony/entry/src/main/resources/en_US/element/string.json"),
    ("es_ES", "harmony/entry/src/main/resources/es_ES/element/string.json"),
    ("fr_FR", "harmony/entry/src/main/resources/fr_FR/element/string.json"),
    ("zh_TW", "harmony/entry/src/main/resources/zh_TW/element/string.json"),
]
APPLE = [("macos", "macos/Localization"), ("ios", "ios/Localization")]

HAN = re.compile(r"[\u4e00-\u9fff]")
ALLOW_HAN_KEYS = {"beian_number"}
ALLOW_HAN_SUBSTR = ("余音", "Reverb")


def read_xml(path):
    s = open(path, encoding="utf-8").read()
    return dict(re.findall(r'<string name="([^"]+)"[^>]*>(.*?)</string>', s, re.S))


def read_hjson(path):
    arr = json.load(open(path, encoding="utf-8"))["string"]
    return {x["name"]: x["value"] for x in arr}


def read_strings(path):
    s = open(path, encoding="utf-8").read()
    return {
        m.group(1): m.group(2)
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', s)
    }


def check_group(name, entries, reader, verbose):
    problems = []
    base_label, base_rel = entries[0]
    base = reader(os.path.join(ROOT, base_rel))
    print(f"[{name}] 基础语言 {base_label}:{len(base)} 条")
    for label, rel in entries[1:]:
        path = os.path.join(ROOT, rel)
        d = reader(path)
        missing = sorted(set(base) - set(d))
        extra = sorted(set(d) - set(base))
        print(f"  {label:7s} {len(d):4d} 条  缺 {len(missing):3d}  多 {len(extra):3d}")
        if missing:
            problems.append(f"{name}/{label} 缺键 {len(missing)}:{missing[:5]}")
        if extra:
            problems.append(f"{name}/{label} 多键 {len(extra)}:{extra[:5]}")
        if label in ("zh-rTW", "zh_TW", "zh-Hant"):
            bad = [(k, "".join(sorted(set(v) & SIMPLIFIED_ONLY)))
                   for k, v in d.items() if set(v) & SIMPLIFIED_ONLY]
            if bad:
                problems.append(f"{name}/{label} 含简体独有字 {len(bad)}:{bad[:3]}")
        if label in ("en", "en_US", "es", "es_ES", "fr", "fr_FR"):
            bad = [(k, v[:20]) for k, v in d.items()
                   if k not in ALLOW_HAN_KEYS and HAN.search(v)
                   and not any(a in v for a in ALLOW_HAN_SUBSTR)]
            if bad:
                problems.append(f"{name}/{label} 含汉字 {len(bad)}:{bad[:3]}")
        if verbose and label in ("es", "es_ES", "fr", "fr_FR"):
            same = [k for k, v in d.items()
                    if k in base and v == base[k] and len(v) > 3]
            if same:
                print(f"         与基础语言同形 {len(same)} 条(同形词/品牌,仅参考):{same[:6]}")
    return problems


def check_apple(root_label, rel, verbose):
    base = read_strings(os.path.join(ROOT, rel, "en.lproj/Localizable.strings"))
    print(f"[{root_label}] 基准 en.lproj:{len(base)} 条")
    problems = []
    for loc in ("es", "fr", "zh-Hant"):
        d = read_strings(os.path.join(ROOT, rel, f"{loc}.lproj/Localizable.strings"))
        missing = sorted(set(base) - set(d))
        extra = sorted(set(d) - set(base))
        print(f"  {loc:7s} {len(d):4d} 条  缺 {len(missing):3d}  多 {len(extra):3d}")
        if missing:
            problems.append(f"{root_label}/{loc} 缺键 {len(missing)}:{missing[:5]}")
        if extra:
            problems.append(f"{root_label}/{loc} 多键 {len(extra)}:{extra[:5]}")
        if loc == "zh-Hant":
            bad = [(k, "".join(sorted(set(v) & SIMPLIFIED_ONLY)))
                   for k, v in d.items() if set(v) & SIMPLIFIED_ONLY]
            if bad:
                problems.append(f"{root_label}/{loc} 含简体独有字 {len(bad)}:{bad[:3]}")
        else:
            bad = [(k, v[:20]) for k, v in d.items()
                   if k not in ALLOW_HAN_KEYS and HAN.search(v)
                   and not any(a in v for a in ALLOW_HAN_SUBSTR)]
            if bad:
                problems.append(f"{root_label}/{loc} 含汉字 {len(bad)}:{bad[:3]}")
            if verbose:
                same = [k for k, v in d.items() if k in base and v == base[k] and len(v) > 3]
                if same:
                    print(f"         与 en 同形 {len(same)} 条(同形词/品牌,仅参考):{same[:6]}")
    return problems


def main():
    verbose = "-v" in sys.argv
    problems = []
    problems += check_group("Android", ANDROID, read_xml, verbose)
    problems += check_group("Harmony", HARMONY, read_hjson, verbose)
    for label, rel in APPLE:
        problems += check_apple(label, rel, verbose)
    print()
    if problems:
        print(f"FAIL:{len(problems)} 项")
        for p in problems:
            print("  -", p)
        return 1
    print("PASS:键集、繁体用字、非中文含汉字三项均无问题")
    return 0


if __name__ == "__main__":
    sys.exit(main())
