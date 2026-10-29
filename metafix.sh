#!/system/bin/sh
# ---------------------------------------------------------------------------
# metafix.sh — 音频标签补全 / 修正（不重新编码，音频数据一个字节都不动）
#
# 配套：同目录下的 libmediacore.so（和 mediaconv.sh 共用同一个）
#
# 转格式时如果丢过标签，或者手头有一堆「光秃秃」的文件，用它补回来：
#   - 从文件名猜：  洛天依 - 世末歌者.mp3  →  歌手=洛天依  标题=世末歌者
#   - 从模板抄：    把另一首歌的标签整体复制过来
#   - 手动指定：    --artist xxx --album yyy
#   - 只缺什么补什么，已有的标签不会被覆盖（--force 才覆盖）
#
# 用法：
#   sh metafix.sh                      交互向导
#   sh metafix.sh 歌曲.mp3              按文件名补全这一首
#   sh metafix.sh -r 音乐目录/           整个目录递归补全
#   sh metafix.sh -n -r 目录/            只体检，列出每首缺什么，不改文件
#   sh metafix.sh --check 目录/         同上（体检模式）
#   sh metafix.sh --from 模板.flac 目标.mp3   把模板的标签抄过去
#   sh metafix.sh --artist 某某 --album 某某 目录/
#   sh metafix.sh -b 目录/              改之前把原文件备份到 修复前备份/
#   sh metafix.sh -o 修好的/ 目录/       改完另存，不动原文件
#
# 说明：改文件是「先写临时文件 → 成功后再替换」，中途出错不会毁掉原文件。
# ---------------------------------------------------------------------------

set -u

PROG=metafix.sh
VERSION=1.0

# ---------- 定位脚本目录 ----------
SELF=$0
case $SELF in
    */*) ;;
    *) SELF=./$SELF ;;
esac
DIR=$(CDPATH= cd "$(dirname "$SELF")" 2>/dev/null && pwd) || {
    echo "$PROG: 无法定位脚本目录" >&2
    exit 1
}
SO=$DIR/libmetacore.so
[ -f "$SO" ] || SO=$DIR/libmediacore.so
[ -f "$SO" ] || SO=$DIR/mediacore.so

# ---------- 默认值 ----------
RECURSE=0
DRYRUN=0
FORCE=0
BACKUP=0
OUTDIR=
TPL=
CHECK_ONLY=0
USE_FILENAME=1
set_title=
set_artist=
set_album=
set_album_artist=
set_date=
set_genre=
set_track=
declare_list=
ARGN=$#

# ---------- 帮助 ----------
usage() {
    cat <<EOF
$PROG $VERSION — 音频标签补全（不重新编码）

用法:
  sh $PROG [选项] [文件或目录...]

选项:
  -r              递归处理子目录
  -n, --check     只检查，列出缺哪些标签，不改任何文件
  -y              不再二次确认
  -f, --force     已有标签也覆盖（默认只补缺失的）
  -b              修改前把原文件备份到 ./修复前备份/
  -o <目录>       改完另存到这个目录，原文件不动
  --from <文件>   从指定文件复制全部标签（歌名/歌手/专辑/年份/风格等）
  --no-filename   不从文件名猜标签
  --title <值>    手动指定歌名
  --artist <值>   手动指定歌手
  --album <值>    手动指定专辑
  --album-artist <值>
  --date <值>     年份/日期
  --genre <值>    风格
  --track <值>    音轨号
  -h, --help      显示本帮助

文件名解析规则（按顺序尝试）:
  "歌手 - 标题.mp3"     → artist=歌手, title=标题
  "01 - 标题.mp3"       → track=01, title=标题
  "01. 标题.mp3"        → track=01, title=标题
  "标题.mp3"            → title=标题

支持的格式: mp3 flac m4a aac ogg wav opus ape wma mka

依赖: 同目录的 libmediacore.so（必须与 $PROG 放在一起）
EOF
}

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        -r) RECURSE=1 ;;
        -n|--check) DRYRUN=1 ;;
        -y) : ;;    # 兼容旧习惯：本脚本本来就不再二次确认
        -f|--force) FORCE=1 ;;
        -b) BACKUP=1 ;;
        -o) shift; [ $# -gt 0 ] || { echo "$PROG: -o 需要参数" >&2; exit 2; }; OUTDIR=$1 ;;
        --from) shift; [ $# -gt 0 ] || { echo "$PROG: --from 需要参数" >&2; exit 2; }; TPL=$1 ;;
        --no-filename) USE_FILENAME=0 ;;
        --title) shift; [ $# -gt 0 ] || exit 2; set_title=$1 ;;
        --artist) shift; [ $# -gt 0 ] || exit 2; set_artist=$1 ;;
        --album) shift; [ $# -gt 0 ] || exit 2; set_album=$1 ;;
        --album-artist) shift; [ $# -gt 0 ] || exit 2; set_album_artist=$1 ;;
        --date) shift; [ $# -gt 0 ] || exit 2; set_date=$1 ;;
        --genre) shift; [ $# -gt 0 ] || exit 2; set_genre=$1 ;;
        --track) shift; [ $# -gt 0 ] || exit 2; set_track=$1 ;;
        -*) echo "$PROG: 未知选项 $1（-h 查看帮助）" >&2; exit 2 ;;
        *) declare_list="$declare_list
$1" ;;
    esac
    shift
done


# ---------- 找到可执行的核心 ----------
RUN_SO=

try_run() {
    [ -n "$1" ] || return 1
    [ -f "$1" ] || return 1
    "$1" -h >/dev/null 2>&1
}

find_so() {
    [ -f "$SO" ] || return 1
    if try_run "$SO"; then
        RUN_SO=$SO
        return 0
    fi

    parent_pkg=
    if [ -r /proc/$PPID/cmdline ]; then
        parent_pkg=$(tr '\0' '\n' < /proc/$PPID/cmdline 2>/dev/null | head -n 1)
        case $parent_pkg in
            *[!a-zA-Z0-9._]*) parent_pkg= ;;
        esac
    fi

    cand_dirs=
    [ -n "${TMPDIR:-}" ] && cand_dirs="$cand_dirs $TMPDIR"
    [ -n "${PREFIX:-}" ] && cand_dirs="$cand_dirs $PREFIX/tmp"
    [ -n "${HOME:-}" ] && cand_dirs="$cand_dirs $HOME/.cache $HOME/tmp"
    [ -n "$parent_pkg" ] && cand_dirs="$cand_dirs /data/data/$parent_pkg/cache /data/user/0/$parent_pkg/cache"
    cand_dirs="$cand_dirs /data/local/tmp /dev/shm /tmp"

    tried=
    for d in $cand_dirs; do
        [ -d "$d" ] && [ -w "$d" ] || continue
        t=$d/.metafix.$$
        if cp "$SO" "$t" 2>/dev/null; then
            chmod 700 "$t" 2>/dev/null
            if try_run "$t"; then
                RUN_SO=$t
                RUN_TMP=$t        # 只登记这份临时副本，后面统一清掉，绝不能碰原文件
                return 0
            fi
            rm -f "$t" 2>/dev/null
            tried="$tried $d(不可执行)"
        else
            tried="$tried $d(不可写)"
        fi
    done
    SO_TRIED=$tried
    return 1
}

if [ ! -f "$SO" ]; then
    echo "$PROG: 找不到 $SO" >&2
    echo "请把 libmediacore.so 与本脚本放在同一个文件夹里。" >&2
    exit 1
fi

if ! find_so; then
    echo "$PROG: 核心文件无法执行" >&2
    echo "$SO" >&2
    [ -n "${SO_TRIED:-}" ] && echo "试过:$SO_TRIED" >&2
    echo "手动复制到可执行目录再跑：" >&2
    echo "  cp libmediacore.so /data/local/tmp/ && chmod 700 /data/local/tmp/libmediacore.so" >&2
    exit 1
fi

# ---------- 交互向导 ----------
if [ "$ARGN" -eq 0 ]; then
    printf '\n'
    printf '  音频标签补全 %s\n' "$VERSION"
    printf '  ------------------------------------\n\n'
    printf '  标签从哪里来？\n\n'
    printf '    1) 从文件名猜（歌手 - 歌名.mp3）\n'
    printf '    2) 从另一个文件复制（模板）\n'
    printf '    3) 我手动填\n\n'
    printf '  序号 [1]: '
    a=
    read -r a 2>/dev/null || a=
    case $a in
        2)
            printf '\n  模板文件路径（把它的标签抄给所有目标）: '
            read -r TPL 2>/dev/null || TPL=
            ;;
        3)
            printf '\n  歌手: '
            read -r set_artist 2>/dev/null || set_artist=
            printf '  专辑: '
            read -r set_album 2>/dev/null || set_album=
            USE_FILENAME=1
            ;;
        *) USE_FILENAME=1 ;;
    esac

    printf '\n  是不是连子文件夹一起处理？[y/N]: '
    read -r a 2>/dev/null || a=
    case $a in
        y|Y|yes|YES) RECURSE=1 ;;
        *) RECURSE=0 ;;
    esac

    printf '\n  要处理的目录或文件（直接回车=当前目录）: '
    read -r a 2>/dev/null || a=
    [ -n "$a" ] && declare_list="$declare_list
$a"
    [ -n "$a" ] || declare_list="$declare_list
."
    printf '\n'
fi

# ---------- 模板标签预读 ----------
tpl_title=; tpl_artist=; tpl_album=; tpl_album_artist=
tpl_date=; tpl_genre=; tpl_track=
if [ -n "$TPL" ]; then
    [ -f "$TPL" ] || { echo "$PROG: 模板文件不存在: $TPL" >&2; exit 2; }
    tpl_info=$("$RUN_SO" -probe "$TPL" 2>/dev/null) || {
        echo "$PROG: 读不了模板文件: $TPL" >&2
        exit 2
    }
    tpl_title=$(printf '%s\n' "$tpl_info" | sed -n 's/^title=//p')
    tpl_artist=$(printf '%s\n' "$tpl_info" | sed -n 's/^artist=//p')
    tpl_album=$(printf '%s\n' "$tpl_info" | sed -n 's/^album=//p')
    tpl_album_artist=$(printf '%s\n' "$tpl_info" | sed -n 's/^album_artist=//p')
    tpl_date=$(printf '%s\n' "$tpl_info" | sed -n 's/^date=//p')
    tpl_genre=$(printf '%s\n' "$tpl_info" | sed -n 's/^genre=//p')
    tpl_track=$(printf '%s\n' "$tpl_info" | sed -n 's/^track=//p')

    if [ -z "$tpl_title" ] && [ -z "$tpl_artist" ]; then
        echo "$PROG: 模板文件里没有标签可用: $TPL" >&2
        exit 2
    fi
fi

# ---------- 收集文件 ----------
LIST=${TMPDIR:-/tmp}/.metafix_list.$$
: > "$LIST" 2>/dev/null || LIST=/data/local/tmp/.metafix_list.$$
trap 'rm -f "$LIST" "$LIST.2" ${RUN_TMP:+"$RUN_TMP"}' EXIT HUP INT TERM

is_audio() {
    case ${1##*.} in
        mp3|MP3|flac|FLAC|wav|WAV|m4a|M4A|mp4|MP4|aac|AAC|ogg|OGG|opus|OPUS|wma|WMA|ape|APE|alac|ALAC|mka|MKA|aif|AIF|aiff|AIFF) return 0 ;;
    esac
    return 1
}

add_file() {
    [ -f "$1" ] || return 0
    is_audio "$1" || return 0
    printf '%s\n' "$1" >> "$LIST"
}

scan_dir() {
    d=$1
    if [ "$RECURSE" = 1 ]; then
        find "$d" -type f 2>/dev/null | while IFS= read -r f; do
            is_audio "$f" && printf '%s\n' "$f"
        done >> "$LIST"
    else
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            is_audio "$f" && printf '%s\n' "$f"
        done >> "$LIST"
    fi
}

if [ -n "$declare_list" ]; then
    printf '%s\n' "$declare_list" | sed '/^$/d' > "$LIST.2"
    while IFS= read -r p; do
        if [ -d "$p" ]; then
            scan_dir "$p"
        else
            add_file "$p"
        fi
    done < "$LIST.2"
else
    scan_dir .
fi

total=$(wc -l < "$LIST" 2>/dev/null | tr -d ' ')
case $total in ''|*[!0-9]*) total=0 ;; esac

if [ "$total" -eq 0 ]; then
    echo "$PROG: 没找到可处理的音频文件" >&2
    [ "$RECURSE" = 0 ] && echo "  当前目录不递归，子目录里的请加 -r" >&2
    exit 1
fi

# ---------- 从文件名猜标签 ----------
NAME_ARTIST=
NAME_TITLE=
NAME_TRACK=

parse_name() {
    base=$(basename "$1")
    base=${base%.*}
    NAME_ARTIST=
    NAME_TITLE=
    NAME_TRACK=

    # 开头的曲目号：01 / 01. / 01 - / 01_
    case $base in
        [0-9]*)
            n=${base%%[!0-9]*}
            if [ ${#n} -le 3 ]; then
                rest=${base#"$n"}
                case $rest in
                    " - "*) rest=${rest# - } ;;
                    ". "*)  rest=${rest#. } ;;
                    "_ "*)  rest=${rest#_ } ;;
                    " "*)   rest=${rest# } ;;
                    "-"*)   rest=${rest#-} ;;
                esac
                NAME_TRACK=$n
                base=$rest
            fi
            ;;
    esac

    case $base in
        *" - "*)
            NAME_ARTIST=${base%%" - "*}
            NAME_TITLE=${base#*" - "}
            ;;
        *)
            NAME_TITLE=$base
            ;;
    esac

    NAME_TITLE=${NAME_TITLE% }
    NAME_ARTIST=${NAME_ARTIST% }
}

# ---------- 组装参数 ----------
run_copy() {
    src=$1
    dst=$2
    shift 2
    "$RUN_SO" -copy "$src" "$dst" "$@" 2>/dev/null
}

# ---------- 主循环 ----------
ok=0
skip=0
fail=0
changed=0

do_one() {
    f=$1
    info=$("$RUN_SO" -probe "$f" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$info" ]; then
        printf '  ! %s\n      读不出来，跳过\n' "$f"
        fail=$((fail + 1))
        return
    fi

    g() { printf '%s\n' "$info" | sed -n "s/^$1=//p"; }
    c_title=$(g title)
    c_artist=$(g artist)
    c_album=$(g album)
    c_album_artist=$(g album_artist)
    c_date=$(g date)
    c_genre=$(g genre)
    c_track=$(g track)
    c_cover=$(g cover)

    # 每个字段：缺了才补（除非 --force）
    w_title=; w_artist=; w_album=; w_album_artist=; w_date=; w_genre=; w_track=

    if [ -n "$TPL" ]; then
        [ -n "$tpl_title" ] && { [ -z "$c_title" ] || [ "$FORCE" = 1 ]; } && w_title=$tpl_title
        [ -n "$tpl_artist" ] && { [ -z "$c_artist" ] || [ "$FORCE" = 1 ]; } && w_artist=$tpl_artist
        [ -n "$tpl_album" ] && { [ -z "$c_album" ] || [ "$FORCE" = 1 ]; } && w_album=$tpl_album
        [ -n "$tpl_album_artist" ] && { [ -z "$c_album_artist" ] || [ "$FORCE" = 1 ]; } && w_album_artist=$tpl_album_artist
        [ -n "$tpl_date" ] && { [ -z "$c_date" ] || [ "$FORCE" = 1 ]; } && w_date=$tpl_date
        [ -n "$tpl_genre" ] && { [ -z "$c_genre" ] || [ "$FORCE" = 1 ]; } && w_genre=$tpl_genre
        [ -n "$tpl_track" ] && { [ -z "$c_track" ] || [ "$FORCE" = 1 ]; } && w_track=$tpl_track
    fi

    if [ "$USE_FILENAME" = 1 ] && [ -z "$w_title" ]; then
        parse_name "$f"
        [ -n "$NAME_TITLE" ] && { [ -z "$c_title" ] || [ "$FORCE" = 1 ]; } && w_title=$NAME_TITLE
        [ -n "$NAME_ARTIST" ] && { [ -z "$c_artist" ] || [ "$FORCE" = 1 ]; } && w_artist=$NAME_ARTIST
        [ -n "$NAME_TRACK" ] && { [ -z "$c_track" ] || [ "$FORCE" = 1 ]; } && w_track=$NAME_TRACK
    fi

    # 手动指定的优先级最高，直接覆盖
    [ -n "$set_title" ] && w_title=$set_title
    [ -n "$set_artist" ] && w_artist=$set_artist
    [ -n "$set_album" ] && w_album=$set_album
    [ -n "$set_album_artist" ] && w_album_artist=$set_album_artist
    [ -n "$set_date" ] && w_date=$set_date
    [ -n "$set_genre" ] && w_genre=$set_genre
    [ -n "$set_track" ] && w_track=$set_track

    # 空值不能拿去写（会被当成删除标签）
    [ -n "$w_title" ] || w_title=
    need=
    [ -n "$w_title" ] && need=1
    [ -n "$w_artist" ] && need=1
    [ -n "$w_album" ] && need=1
    [ -n "$w_album_artist" ] && need=1
    [ -n "$w_date" ] && need=1
    [ -n "$w_genre" ] && need=1
    [ -n "$w_track" ] && need=1

    if [ -z "$need" ]; then
        printf '  - %s\n      标签齐全，不动\n' "$(basename "$f")"
        skip=$((skip + 1))
        return
    fi

    # 显示要补什么
    summary=
    [ -n "$w_title" ] && summary="$summary 歌名[$w_title]"
    [ -n "$w_artist" ] && summary="$summary 歌手[$w_artist]"
    [ -n "$w_album" ] && summary="$summary 专辑[$w_album]"
    [ -n "$w_album_artist" ] && summary="$summary 专辑歌手[$w_album_artist]"
    [ -n "$w_date" ] && summary="$summary 年份[$w_date]"
    [ -n "$w_genre" ] && summary="$summary 风格[$w_genre]"
    [ -n "$w_track" ] && summary="$summary 音轨[$w_track]"

    if [ "$DRYRUN" = 1 ]; then
        printf '  ? %s\n      缺→%s\n' "$(basename "$f")" "$summary"
        changed=$((changed + 1))
        return
    fi

    # 目标路径
    case $f in
        */*) fdir=${f%/*} ;;
        *) fdir=. ;;
    esac
    fext=${f##*.}

    if [ -n "$OUTDIR" ]; then
        mkdir -p "$OUTDIR" 2>/dev/null
        dst=$OUTDIR/$(basename "$f")
    else
        dst=$fdir/.metafix_$$.tmp.$fext
    fi

    set --
    [ -n "$w_title" ] && set -- "$@" "title=$w_title"
    [ -n "$w_artist" ] && set -- "$@" "artist=$w_artist"
    [ -n "$w_album" ] && set -- "$@" "album=$w_album"
    [ -n "$w_album_artist" ] && set -- "$@" "album_artist=$w_album_artist"
    [ -n "$w_date" ] && set -- "$@" "date=$w_date"
    [ -n "$w_genre" ] && set -- "$@" "genre=$w_genre"
    [ -n "$w_track" ] && set -- "$@" "track=$w_track"

    if ! run_copy "$f" "$dst" "$@"; then
        rm -f "$dst" 2>/dev/null
        printf '  ! %s\n      写入失败\n' "$(basename "$f")"
        fail=$((fail + 1))
        return
    fi

    if [ ! -s "$dst" ]; then
        rm -f "$dst" 2>/dev/null
        printf '  ! %s\n      输出是空文件，已丢弃\n' "$(basename "$f")"
        fail=$((fail + 1))
        return
    fi

    if [ -z "$OUTDIR" ]; then
        [ "$BACKUP" = 1 ] && {
            mkdir -p "$DIR/修复前备份" 2>/dev/null
            cp -p "$f" "$DIR/修复前备份/$(basename "$f")" 2>/dev/null
        }
        if mv -f "$dst" "$f" 2>/dev/null; then
            printf '  + %s\n      %s\n' "$(basename "$f")" "$summary"
            ok=$((ok + 1))
        else
            rm -f "$dst" 2>/dev/null
            printf '  ! %s\n      替换原文件失败（原文件没动）\n' "$(basename "$f")"
            fail=$((fail + 1))
        fi
    else
        printf '  + %s\n      → %s\n      %s\n' "$(basename "$f")" "$dst" "$summary"
        ok=$((ok + 1))
    fi
}

printf '\n  处理 %s 个文件' "$total"
if [ "$DRYRUN" = 1 ]; then printf '（体检模式，不会改动任何文件）'; fi
printf '\n\n'

while IFS= read -r f; do
    [ -n "$f" ] || continue
    do_one "$f"
done < "$LIST"

# ---------- 汇总 ----------
printf '\n  ------------------------------------\n'
if [ "$DRYRUN" = 1 ]; then
    printf '  体检完成：%s 个文件需要补标签，%s 个已经齐全' "$changed" "$skip"
    [ "$fail" -gt 0 ] && printf '，%s 个读不出来' "$fail"
    printf '\n  去掉 -n 就会真的写入。\n\n'
else
    printf '  完成：改了 %s 个，跳过 %s 个' "$ok" "$skip"
    [ "$fail" -gt 0 ] && printf '，失败 %s 个' "$fail"
    printf '\n\n'
fi

[ "$fail" -gt 0 ] && exit 1
exit 0
