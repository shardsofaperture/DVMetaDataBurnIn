import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            Text("DVMetaDataBurnIn")
                .font(.title2)
                .bold()

            Text("DV date/time burn-in tool for DV and Digital8 clips, using dvrescue metadata and ffmpeg for rendering.")
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // MIT license
            Group {
                Text("App License (MIT)")
                    .font(.headline)

                Text("""
                Copyright (c) 2025 Zach Zarzycki

                Permission is hereby granted, free of charge, to any person obtaining a copy
                of this software and associated documentation files (the \"Software\"), to deal
                in the Software without restriction, including without limitation the rights
                to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                copies of the Software, and to permit persons to whom the Software is
                furnished to do so, subject to the following conditions:

                The above copyright notice and this permission notice shall be included in
                all copies or substantial portions of the Software.

                THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
                THE SOFTWARE.
                """)
                .font(.system(.footnote, design: .monospaced))
            }

            
            Divider()
            Spacer(minLength: 16)
            
            // Dedication
            Text("Dedicated to Carisa who lovingly puts up with my hobbies")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 16)

            Divider()

            // Bundled tools + skull at bottom-right
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundled Tools")
                        .font(.headline)

                    Text("""
                    This application bundles:

                    • FFmpeg, © the FFmpeg developers, under LGPL/GPL.
                      See the included LICENSE and COPYING.* files in the app bundle,
                      and ffmpeg.org for source and details.

                    • dvrescue, © Moving Image Preservation of Puget Sound (MIPoPS),
                      under the BSD 3-Clause License.
                      See dvrescue_LICENSE.txt in the app bundle and mediaarea.net/DVRescue for details.
                    """)
                    .font(.system(.footnote, design: .monospaced))
                }

                Spacer()

                Image("skullhawk")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120)          // tweak size here
                    .padding(.top, 4)
            }

            Spacer()

            HStack {
                Spacer()
                Text("All included licenses are in Resources/licenses inside the app bundle.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 480)
    }
}
