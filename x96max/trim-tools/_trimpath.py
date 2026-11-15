"""在 x96max/trim-tools 里找到共享的 trimlib.py（判据单点在 tools/trim/）。

trim-tools 在构建机上以 /x96-build/trim-tools 软链过来，所以用 realpath 再上溯两级；
真独立拷走时退回同目录——但那时判据就分叉了，别拷。
"""
import os, sys

HERE = os.path.dirname(os.path.realpath(__file__))
for cand in (os.path.join(HERE, '../../tools/trim'), HERE):
    if os.path.exists(os.path.join(cand, 'trimlib.py')):
        sys.path.insert(0, cand)
        break
else:
    sys.exit('找不到 trimlib.py（应在 %s/../../tools/trim/）' % HERE)
