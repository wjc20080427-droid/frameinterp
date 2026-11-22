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

## Trademarks

PlayStation, PS5, Xbox, Xbox Series X|S, ShadowCast, Genki, Elgato, AVerMedia and other product names are
trademarks of their respective owners. FrameInterp is an independent project and is not affiliated with,
endorsed by, or sponsored by any of them. Product names are used only to describe compatibility.
