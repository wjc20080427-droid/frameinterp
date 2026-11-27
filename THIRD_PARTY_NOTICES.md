# Third-party notices

FrameInterp is licensed under the GNU General Public License v3.0 (see `LICENSE`).
It includes code derived from the following third-party work.

## AMD FidelityFX Super Resolution 1 (FSR 1) — RCAS

The luma sharpening pass in `Sources/FrameInterp/SharpScaler.swift` and `Sources/FrameInterp/Enhancer.swift`
(`rcasY`, Robust Contrast Adaptive Sharpening) is a Metal port of the RCAS algorithm from AMD FidelityFX FSR 1.

```
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## WebRTC

Release builds bundle `WebRTC.framework`, a build of Google WebRTC (M158) from the community project
[stasel/WebRTC](https://github.com/stasel/WebRTC), used for native Xbox streaming. It is not in this repository
(`tools/fetch-webrtc.sh` downloads it). Its license is also shipped in the app as `Resources/WebRTC-LICENSE.txt`.

```
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Xbox streaming protocol

The native Xbox streaming code (`XboxAccount.swift`, `XboxStream.swift`) was written for FrameInterp, using the
MIT-licensed [xbox-xcloud-player](https://github.com/unknownskl/xbox-xcloud-player) project as a reference for the
protocol. No Microsoft code is included.

## Trademarks

PlayStation, PS5, Xbox, Xbox Series X|S, ShadowCast, Genki, Elgato, AVerMedia and other product names are
trademarks of their respective owners. FrameInterp is an independent project and is not affiliated with,
endorsed by, or sponsored by any of them. Product names are used only to describe compatibility.
