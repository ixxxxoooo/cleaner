#!/bin/zsh
# 以指定启动参数运行应用并截取窗口截图（调试用）
# 用法：./shot.sh 输出名 [-section projects] [-selectRecommended 1] ...
# @author ygw
name=$1; shift
pkill -x Cleaner 2>/dev/null; sleep 1
open -n "$(dirname "$0")/build/Build/Products/Debug/Cleaner.app" --args "$@"
sleep 7
osascript -e 'tell application id "ixxxxoooo" to activate'
sleep 1.5
id=$(/tmp/win | grep -E '^[0-9]+' | awk '{print $1}' | head -1)
screencapture -x -l "$id" "/tmp/$name.png"
sips -Z 1600 "/tmp/$name.png" >/dev/null
echo "/tmp/$name.png"
