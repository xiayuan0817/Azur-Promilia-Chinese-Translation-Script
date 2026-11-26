# Shared PowerShell 5.1 core helpers and C# native acceleration for Azur Promilia localization.

if (-not ('LocalizationCRC' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class LocalizationCRC {
    private static readonly uint[][] Tables = MakeTables();

    private static uint[][] MakeTables() {
        uint[][] t = new uint[8][];
        for (int s = 0; s < 8; s++) t[s] = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int j = 0; j < 8; j++) c = (c >> 1) ^ ((c & 1) != 0 ? 0xEDB88320u : 0u);
            t[0][i] = c;
        }
        for (int s = 1; s < 8; s++) {
            for (int i = 0; i < 256; i++) {
                uint prev = t[s - 1][i];
                t[s][i] = (prev >> 8) ^ t[0][prev & 0xFFu];
            }
        }
        return t;
    }

    public static uint UpdateSlicing8(uint crc, byte[] buf, int offset, int count) {
        int end = offset + count;
        int p = offset;
        uint[][] t = Tables;
        while (p + 8 <= end) {
            uint lo = (uint)(buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16) | (buf[p + 3] << 24));
            uint hi = (uint)(buf[p + 4] | (buf[p + 5] << 8) | (buf[p + 6] << 16) | (buf[p + 7] << 24));
            crc ^= lo;
            crc = t[7][crc & 0xFFu] ^
                  t[6][(crc >> 8) & 0xFFu] ^
                  t[5][(crc >> 16) & 0xFFu] ^
                  t[4][(crc >> 24) & 0xFFu] ^
                  t[3][hi & 0xFFu] ^
                  t[2][(hi >> 8) & 0xFFu] ^
                  t[1][(hi >> 16) & 0xFFu] ^
                  t[0][(hi >> 24) & 0xFFu];
            p += 8;
        }
        uint[] t0 = t[0];
        while (p < end) {
            crc = t0[(crc ^ buf[p]) & 0xFFu] ^ (crc >> 8);
            p++;
        }
        return crc;
    }

    public static uint Range(string path, long offset, long length) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan)) {
            if (offset < 0 || length < 0 || offset > f.Length || length > f.Length - offset)
                throw new InvalidDataException("CRC range outside file");
            f.Position = offset;
            byte[] b = new byte[1048576];
            uint c = 0xFFFFFFFFu;
            while (length > 0) {
                int n = f.Read(b, 0, (int)Math.Min(b.Length, length));
                if (n == 0) throw new EndOfStreamException();
                c = UpdateSlicing8(c, b, 0, n);
                length -= n;
            }
            return c ^ 0xFFFFFFFFu;
        }
    }
}
'@
}

if (-not ('LocalizationNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

public static class LocalizationNative {
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private static readonly uint[][] Tables = MakeTables();

    private static uint[][] MakeTables() {
        uint[][] t = new uint[8][];
        for (int s = 0; s < 8; s++) t[s] = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int j = 0; j < 8; j++) c = (c >> 1) ^ ((c & 1) != 0 ? 0xEDB88320u : 0u);
            t[0][i] = c;
        }
        for (int s = 1; s < 8; s++) {
            for (int i = 0; i < 256; i++) {
                uint prev = t[s - 1][i];
                t[s][i] = (prev >> 8) ^ t[0][prev & 0xFFu];
            }
        }
        return t;
    }

    private static uint UpdateSlicing8(uint crc, byte[] buf, int offset, int count) {
        int end = offset + count;
        int p = offset;
        uint[][] t = Tables;
        while (p + 8 <= end) {
            uint lo = (uint)(buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16) | (buf[p + 3] << 24));
            uint hi = (uint)(buf[p + 4] | (buf[p + 5] << 8) | (buf[p + 6] << 16) | (buf[p + 7] << 24));
            crc ^= lo;
            crc = t[7][crc & 0xFFu] ^
                  t[6][(crc >> 8) & 0xFFu] ^
                  t[5][(crc >> 16) & 0xFFu] ^
                  t[4][(crc >> 24) & 0xFFu] ^
                  t[3][hi & 0xFFu] ^
                  t[2][(hi >> 8) & 0xFFu] ^
                  t[1][(hi >> 16) & 0xFFu] ^
                  t[0][(hi >> 24) & 0xFFu];
            p += 8;
        }
        uint[] t0 = t[0];
        while (p < end) {
            crc = t0[(crc ^ buf[p]) & 0xFFu] ^ (crc >> 8);
            p++;
        }
        return crc;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    public static string TryGetProcessImagePath(int pid) {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            int cap = 1024;
            StringBuilder sb = new StringBuilder(cap);
            if (QueryFullProcessImageNameW(h, 0, sb, ref cap)) {
                return sb.ToString();
            }
            return null;
        } finally {
            CloseHandle(h);
        }
    }

    private static string BytesToLowerHex(byte[] bytes) {
        char[] c = new char[bytes.Length * 2];
        const string hex = "0123456789abcdef";
        for (int i = 0; i < bytes.Length; i++) {
            int b = bytes[i];
            c[i * 2] = hex[b >> 4];
            c[i * 2 + 1] = hex[b & 0x0F];
        }
        return new string(c);
    }

    public static string ComputeSha256(string path) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan))
        using (SHA256 sha = SHA256.Create()) {
            byte[] buf = new byte[1048576];
            int n;
            while ((n = f.Read(buf, 0, buf.Length)) > 0) {
                sha.TransformBlock(buf, 0, n, null, 0);
            }
            sha.TransformFinalBlock(new byte[0], 0, 0);
            return BytesToLowerHex(sha.Hash);
        }
    }

    public static string ComputeMd5(string path) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan))
        using (MD5 md5 = MD5.Create()) {
            byte[] buf = new byte[1048576];
            int n;
            while ((n = f.Read(buf, 0, buf.Length)) > 0) {
                md5.TransformBlock(buf, 0, n, null, 0);
            }
            md5.TransformFinalBlock(new byte[0], 0, 0);
            return BytesToLowerHex(md5.Hash);
        }
    }

    public static string ComputeRangeSha256(string path, long offset, long length) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan)) {
            if (offset < 0 || length < 0 || offset > f.Length || length > f.Length - offset) {
                throw new InvalidDataException("SHA256 range outside file");
            }
            f.Position = offset;
            using (SHA256 sha = SHA256.Create()) {
                byte[] buf = new byte[1048576];
                while (length > 0) {
                    int n = f.Read(buf, 0, (int)Math.Min(buf.Length, length));
                    if (n == 0) throw new EndOfStreamException();
                    sha.TransformBlock(buf, 0, n, null, 0);
                    length -= n;
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return BytesToLowerHex(sha.Hash);
            }
        }
    }

    public static void VerifyFile(
        string path,
        long expectedSize,
        string expectedSha256,
        bool checkCrc,
        uint expectedFullCrc,
        long[] segOffsets,
        long[] segSizes,
        uint[] segCrcs,
        int[] segIds
    ) {
        if (!File.Exists(path)) {
            throw new FileNotFoundException("文件缺失：" + path);
        }
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan)) {
            if (f.Length != expectedSize) {
                throw new InvalidDataException("文件大小不匹配：" + path);
            }

            int segCount = 0;
            int[] order = null;
            uint[] segStates = null;

            if (checkCrc && segOffsets != null && segOffsets.Length > 0) {
                segCount = segOffsets.Length;
                if (segSizes == null || segCrcs == null || segIds == null ||
                    segSizes.Length != segCount || segCrcs.Length != segCount || segIds.Length != segCount) {
                    throw new ArgumentException("Segment array lengths mismatch");
                }
                order = new int[segCount];
                segStates = new uint[segCount];
                for (int i = 0; i < segCount; i++) {
                    if (segOffsets[i] < 0 || segSizes[i] < 0 || segOffsets[i] > expectedSize || segSizes[i] > expectedSize - segOffsets[i]) {
                        throw new InvalidDataException("CRC range outside file");
                    }
                    order[i] = i;
                    segStates[i] = 0xFFFFFFFFu;
                }
                Array.Sort(order, (a, b) => segOffsets[a].CompareTo(segOffsets[b]));
            }

            using (SHA256 sha = SHA256.Create()) {
                byte[] buf = new byte[1048576];
                uint fullCrc = 0xFFFFFFFFu;
                long pos = 0;
                int nextSeg = 0;
                List<int> active = checkCrc && segCount > 0 ? new List<int>() : null;

                int n;
                while ((n = f.Read(buf, 0, buf.Length)) > 0) {
                    sha.TransformBlock(buf, 0, n, null, 0);
                    if (checkCrc) {
                        fullCrc = UpdateSlicing8(fullCrc, buf, 0, n);
                        if (active != null) {
                            long chunkEnd = pos + n;
                            while (nextSeg < segCount) {
                                int idx = order[nextSeg];
                                if (segOffsets[idx] >= chunkEnd) break;
                                if (segSizes[idx] > 0) active.Add(idx);
                                nextSeg++;
                            }
                            for (int a = active.Count - 1; a >= 0; a--) {
                                int idx = active[a];
                                long segStart = segOffsets[idx];
                                long segEnd = segStart + segSizes[idx];
                                long overlapStart = pos > segStart ? pos : segStart;
                                long overlapEnd = chunkEnd < segEnd ? chunkEnd : segEnd;
                                if (overlapEnd > overlapStart) {
                                    segStates[idx] = UpdateSlicing8(
                                        segStates[idx],
                                        buf,
                                        (int)(overlapStart - pos),
                                        (int)(overlapEnd - overlapStart)
                                    );
                                }
                                if (overlapEnd >= segEnd) {
                                    active.RemoveAt(a);
                                }
                            }
                        }
                    }
                    pos += n;
                }

                sha.TransformFinalBlock(new byte[0], 0, 0);
                string actualSha = BytesToLowerHex(sha.Hash);
                if (!string.IsNullOrEmpty(expectedSha256) && !string.Equals(actualSha, expectedSha256, StringComparison.OrdinalIgnoreCase)) {
                    throw new InvalidDataException("SHA256 不匹配：" + path);
                }

                if (checkCrc) {
                    if ((fullCrc ^ 0xFFFFFFFFu) != expectedFullCrc) {
                        throw new InvalidDataException("整包 CRC 不匹配：" + path);
                    }
                    for (int i = 0; i < segCount; i++) {
                        if ((segStates[i] ^ 0xFFFFFFFFu) != segCrcs[i]) {
                            throw new InvalidDataException("段 CRC 不匹配：" + path + "，段 " + segIds[i]);
                        }
                    }
                }
            }
        }
    }
}
'@
}

if (-not ('LocalizationManifest' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public sealed class YooPackInfo {
    public int PackIndex;
    public string Name;
    public long Size;
    public uint Crc;
}

public sealed class YooBundleInfo {
    public int Index;
    public int PackId;
    public long Offset;
    public long Size;
    public uint Crc;
}

public sealed class YooManifestInfo {
    public string Package;
    public string Version;
    public YooPackInfo[] Packs;
    public YooBundleInfo[] Bundles;
}

public static class LocalizationManifest {
    private const uint Magic = 0x594F4Fu;
    private const string Base38Alpha = " 0123456789abcdefghijklmnopqrstuvwxyz.";

    private static void EnsureBytes(byte[] raw, int pos, long needed) {
        if (needed < 0 || pos < 0 || pos > raw.Length || needed > (long)(raw.Length - pos)) {
            throw new InvalidDataException("YooAsset 清单数据截断或长度异常。");
        }
    }

    private static ushort ReadUInt16LE(byte[] raw, int pos) {
        EnsureBytes(raw, pos, 2);
        return (ushort)(raw[pos] | (raw[pos + 1] << 8));
    }

    private static int ReadInt32LE(byte[] raw, int pos) {
        EnsureBytes(raw, pos, 4);
        return (int)(
            (uint)raw[pos] |
            ((uint)raw[pos + 1] << 8) |
            ((uint)raw[pos + 2] << 16) |
            ((uint)raw[pos + 3] << 24)
        );
    }

    private static uint ReadUInt32LE(byte[] raw, int pos) {
        EnsureBytes(raw, pos, 4);
        return (uint)raw[pos] |
               ((uint)raw[pos + 1] << 8) |
               ((uint)raw[pos + 2] << 16) |
               ((uint)raw[pos + 3] << 24);
    }

    private static ulong ReadUInt64LE(byte[] raw, int pos) {
        EnsureBytes(raw, pos, 8);
        uint lo = ReadUInt32LE(raw, pos);
        uint hi = ReadUInt32LE(raw, pos + 4);
        return ((ulong)hi << 32) | (ulong)lo;
    }

    private static long ReadInt64LE(byte[] raw, int pos) {
        return unchecked((long)ReadUInt64LE(raw, pos));
    }

    private static string ReadString(byte[] raw, ref int pos) {
        ushort len = ReadUInt16LE(raw, pos);
        pos += 2;
        EnsureBytes(raw, pos, len);
        string s = Encoding.UTF8.GetString(raw, pos, len);
        pos += len;
        return s;
    }

    private static string DecodeBase38(ulong n) {
        if (n == 0) return "";
        StringBuilder sb = new StringBuilder();
        while (n > 0) {
            int d = (int)(n % 38UL);
            n /= 38UL;
            sb.Insert(0, Base38Alpha[d]);
        }
        return sb.ToString();
    }

    private static string ComputeMd5(string path) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan))
        using (MD5 md5 = MD5.Create()) {
            byte[] buf = new byte[1048576];
            int n;
            while ((n = f.Read(buf, 0, buf.Length)) > 0) {
                md5.TransformBlock(buf, 0, n, null, 0);
            }
            md5.TransformFinalBlock(new byte[0], 0, 0);
            return BytesToLowerHex(md5.Hash);
        }
    }

    public static YooManifestInfo ParseManifest(string bytesPath, string hashPath) {
        if (!File.Exists(bytesPath)) {
            throw new FileNotFoundException("清单文件缺失：" + bytesPath);
        }
        if (!File.Exists(hashPath)) {
            throw new FileNotFoundException("清单哈希文件缺失：" + hashPath);
        }
        string expectedMd5 = File.ReadAllText(hashPath, Encoding.ASCII).Trim().ToLowerInvariant();
        string actualMd5 = ComputeMd5(bytesPath);
        if (expectedMd5.Length != 32 || !string.Equals(actualMd5, expectedMd5, StringComparison.OrdinalIgnoreCase)) {
            throw new InvalidDataException("清单 MD5 校验失败：" + bytesPath);
        }

        byte[] raw = File.ReadAllBytes(bytesPath);
        int pos = 0;
        uint magic = ReadUInt32LE(raw, pos);
        pos += 4;
        if (magic != Magic) {
            throw new InvalidDataException("无效的 YooAsset 清单头：" + bytesPath);
        }
        ReadString(raw, ref pos); // format
        EnsureBytes(raw, pos, 11); // 3 flags + name_style(4) + bundle_type(4)
        pos += 11;
        ReadString(raw, ref pos); // pipeline
        string packageName = ReadString(raw, ref pos);
        string version = ReadString(raw, ref pos);
        ReadString(raw, ref pos); // note

        int assetCount = ReadInt32LE(raw, pos);
        pos += 4;
        if (assetCount < 0) throw new InvalidDataException("清单 assetCount 无效。");
        long assetBytes = (long)assetCount * 24L;
        EnsureBytes(raw, pos, assetBytes);
        pos += (int)assetBytes;

        int assetDependCount = ReadInt32LE(raw, pos);
        pos += 4;
        if (assetDependCount < 0) throw new InvalidDataException("清单 assetDependCount 无效。");
        long assetDependBytes = (long)assetDependCount * 4L;
        EnsureBytes(raw, pos, assetDependBytes);
        pos += (int)assetDependBytes;

        int bundleCount = ReadInt32LE(raw, pos);
        pos += 4;
        if (bundleCount < 0) throw new InvalidDataException("清单 bundleCount 无效。");
        long bundleBytes = (long)bundleCount * 56L;
        EnsureBytes(raw, pos, bundleBytes);
        YooBundleInfo[] bundles = new YooBundleInfo[bundleCount];
        for (int i = 0; i < bundleCount; i++) {
            int entryPos = pos + i * 56;
            YooBundleInfo b = new YooBundleInfo();
            b.Size = ReadInt64LE(raw, entryPos);
            b.Crc = ReadUInt32LE(raw, entryPos + 8);
            b.PackId = ReadInt32LE(raw, entryPos + 32);
            b.Offset = ReadInt64LE(raw, entryPos + 36);
            b.Index = ReadInt32LE(raw, entryPos + 48);
            bundles[i] = b;
        }
        pos += (int)bundleBytes;

        int refCount = ReadInt32LE(raw, pos);
        pos += 4;
        if (refCount < 0) throw new InvalidDataException("清单 refCount 无效。");
        long refBytes = (long)refCount * 4L;
        EnsureBytes(raw, pos, refBytes);
        pos += (int)refBytes;

        int hashCount = ReadInt32LE(raw, pos);
        pos += 4;
        if (hashCount < 0) throw new InvalidDataException("清单 hashCount 无效。");
        long hashBytes = (long)hashCount * 16L;
        EnsureBytes(raw, pos, hashBytes);
        pos += (int)hashBytes;

        int packCount = ReadInt32LE(raw, pos);
        pos += 4;
        if (packCount < 0) throw new InvalidDataException("清单 packCount 无效。");
        long packBytes = (long)packCount * 48L;
        EnsureBytes(raw, pos, packBytes);
        YooPackInfo[] packs = new YooPackInfo[packCount];
        for (int i = 0; i < packCount; i++) {
            int entryPos = pos + i * 48;
            ulong name0 = ReadUInt64LE(raw, entryPos);
            ulong name1 = ReadUInt64LE(raw, entryPos + 8);
            YooPackInfo pk = new YooPackInfo();
            pk.PackIndex = i;
            pk.Name = DecodeBase38(name0) + DecodeBase38(name1);
            pk.Size = ReadInt64LE(raw, entryPos + 32);
            pk.Crc = ReadUInt32LE(raw, entryPos + 44);
            packs[i] = pk;
        }
        pos += (int)packBytes;

        if (pos != raw.Length) {
            throw new InvalidDataException("YooAsset 清单存在未解析尾部字节。");
        }

        for (int i = 0; i < bundleCount; i++) {
            YooBundleInfo b = bundles[i];
            if (b.PackId < 0 || b.PackId >= packCount) {
                throw new InvalidDataException("YooAsset 清单 bundle packId 越界。");
            }
            YooPackInfo pk = packs[b.PackId];
            if (b.Offset < 0 || b.Size < 0 || b.Offset > pk.Size || b.Size > pk.Size - b.Offset) {
                throw new InvalidDataException("YooAsset 清单 bundle 偏移范围越界。");
            }
        }

        YooManifestInfo info = new YooManifestInfo();
        info.Package = packageName;
        info.Version = version;
        info.Packs = packs;
        info.Bundles = bundles;
        return info;
    }

    public static YooPackInfo FindPackByName(YooManifestInfo manifest, string packName) {
        if (manifest == null || manifest.Packs == null || string.IsNullOrEmpty(packName)) return null;
        for (int i = 0; i < manifest.Packs.Length; i++) {
            if (string.Equals(manifest.Packs[i].Name, packName, StringComparison.OrdinalIgnoreCase)) {
                return manifest.Packs[i];
            }
        }
        return null;
    }

    public static YooBundleInfo[] GetPackBundles(YooManifestInfo manifest, int packId) {
        List<YooBundleInfo> list = new List<YooBundleInfo>();
        if (manifest != null && manifest.Bundles != null) {
            for (int i = 0; i < manifest.Bundles.Length; i++) {
                if (manifest.Bundles[i].PackId == packId) {
                    list.Add(manifest.Bundles[i]);
                }
            }
        }
        list.Sort((a, b) => a.Offset.CompareTo(b.Offset));
        return list.ToArray();
    }

    public static YooBundleInfo[] FindBundles(YooManifestInfo manifest, long size, uint crc) {
        List<YooBundleInfo> list = new List<YooBundleInfo>();
        if (manifest != null && manifest.Bundles != null) {
            for (int i = 0; i < manifest.Bundles.Length; i++) {
                YooBundleInfo b = manifest.Bundles[i];
                if (b.Size == size && b.Crc == crc) {
                    list.Add(b);
                }
            }
        }
        return list.ToArray();
    }

    private static void CopyExact(FileStream src, FileStream dst, SHA256 sha, byte[] buf, long length) {
        while (length > 0) {
            int n = src.Read(buf, 0, (int)Math.Min(buf.Length, length));
            if (n <= 0) throw new EndOfStreamException("复制分段数据时文件提前结束。");
            dst.Write(buf, 0, n);
            sha.TransformBlock(buf, 0, n, null, 0);
            length -= n;
        }
    }

    private static string BytesToLowerHex(byte[] bytes) {
        char[] c = new char[bytes.Length * 2];
        const string hex = "0123456789abcdef";
        for (int i = 0; i < bytes.Length; i++) {
            int b = bytes[i];
            c[i * 2] = hex[b >> 4];
            c[i * 2 + 1] = hex[b & 0x0F];
        }
        return new string(c);
    }

    public static string BuildPatchedPack(
        string basePackPath,
        string[] donorPaths,
        long[] targetOffsets,
        long[] donorOffsets,
        long[] sizes,
        string tempOutPath
    ) {
        if (donorPaths == null || targetOffsets == null || donorOffsets == null || sizes == null || donorPaths.Length == 0) {
            throw new ArgumentException("Patched segment arrays cannot be empty.");
        }
        int count = donorPaths.Length;
        if (targetOffsets.Length != count || donorOffsets.Length != count || sizes.Length != count) {
            throw new ArgumentException("Patched segment array lengths mismatch.");
        }

        int[] order = new int[count];
        for (int i = 0; i < count; i++) order[i] = i;
        Array.Sort(order, (a, b) => targetOffsets[a].CompareTo(targetOffsets[b]));

        using (FileStream baseStream = new FileStream(basePackPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan))
        using (FileStream outStream = new FileStream(tempOutPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1048576))
        using (SHA256 sha = SHA256.Create()) {
            long baseLen = baseStream.Length;
            long prevEnd = 0;
            Dictionary<string, FileStream> donors = new Dictionary<string, FileStream>(StringComparer.OrdinalIgnoreCase);
            try {
                for (int k = 0; k < count; k++) {
                    int idx = order[k];
                    long tOff = targetOffsets[idx];
                    long dOff = donorOffsets[idx];
                    long sz = sizes[idx];
                    string dPath = donorPaths[idx];
                    if (sz <= 0 || tOff < prevEnd || tOff > baseLen || sz > baseLen - tOff) {
                        throw new InvalidDataException("目标段偏移越界或重叠。");
                    }
                    FileStream dStream;
                    if (!donors.TryGetValue(dPath, out dStream)) {
                        dStream = new FileStream(dPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.RandomAccess);
                        donors[dPath] = dStream;
                    }
                    if (dOff < 0 || dOff > dStream.Length || sz > dStream.Length - dOff) {
                        throw new InvalidDataException("来源段偏移越界：" + dPath);
                    }
                    prevEnd = tOff + sz;
                }

                byte[] buf = new byte[1048576];
                long cursor = 0;
                for (int k = 0; k < count; k++) {
                    int idx = order[k];
                    long tOff = targetOffsets[idx];
                    long dOff = donorOffsets[idx];
                    long sz = sizes[idx];
                    if (tOff > cursor) {
                        baseStream.Position = cursor;
                        CopyExact(baseStream, outStream, sha, buf, tOff - cursor);
                    }
                    FileStream dStream = donors[donorPaths[idx]];
                    dStream.Position = dOff;
                    CopyExact(dStream, outStream, sha, buf, sz);
                    cursor = tOff + sz;
                }
                if (cursor < baseLen) {
                    baseStream.Position = cursor;
                    CopyExact(baseStream, outStream, sha, buf, baseLen - cursor);
                }
                outStream.Flush();
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return BytesToLowerHex(sha.Hash);
            } finally {
                foreach (FileStream fs in donors.Values) {
                    fs.Dispose();
                }
            }
        }
    }
}
'@
}

function Assert-NoReparse([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '路径不能为空。' }
    $current = [IO.Path]::GetFullPath($Path)
    if ($current.StartsWith('\\')) { throw "拒绝网络路径：$current" }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "拒绝重解析点路径：$current"
            }
        }
        $parent = Split-Path $current -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Resolve-SafeChild([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) {
        throw "非法相对路径：$Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($base, ($Relative -replace '/', '\')))
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径越界：$Relative"
    }
    Assert-NoReparse $full
    return $full
}

function Get-FileSha256([string]$Path) {
    Assert-NoReparse $Path
    return [LocalizationNative]::ComputeSha256($Path)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not [IO.Directory]::Exists($dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Assert-FreeDiskSpace([string]$TargetDir, [long]$RequiredBytes) {
    if ($RequiredBytes -le 0) { return }
    $full = [IO.Path]::GetFullPath($TargetDir)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root) -or $root.StartsWith('\\')) { return }
    $drive = New-Object System.IO.DriveInfo($root)
    $headroom = [long]67108864 # 64 MB safety headroom
    $needed = $RequiredBytes + $headroom
    if ($drive.AvailableFreeSpace -lt $needed) {
        $needMb = [Math]::Ceiling($needed / 1MB)
        $availMb = [Math]::Floor($drive.AvailableFreeSpace / 1MB)
        throw ("目标磁盘剩余空间不足（$($drive.Name)）：需要约 $needMb MB，当前仅剩 $availMb MB。")
    }
}

function Get-ProcessImagePathSafe([Diagnostics.Process]$Process) {
    $image = [LocalizationNative]::TryGetProcessImagePath($Process.Id)
    if (-not [string]::IsNullOrWhiteSpace($image)) { return $image }
    try {
        return $Process.MainModule.FileName
    } catch {
        return $null
    }
}

function Assert-ProcessesStopped(
    [string[]]$ProcessNames,
    [string[]]$PathScopes,
    [string]$FriendlyError,
    [string[]]$AlwaysRefuseNames = @()
) {
    $normalizedScopes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $PathScopes) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $fullScope = [IO.Path]::GetFullPath($s).TrimEnd('\')
        $rootOnly = [IO.Path]::GetPathRoot($fullScope).TrimEnd('\')
        # Never treat a bare drive root like D:\ as a wildcard process scope.
        if ([string]::Equals($fullScope, $rootOnly, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $normalizedScopes.Add($fullScope + '\')
    }

    foreach ($name in $ProcessNames) {
        $isAlwaysRefuse = ($AlwaysRefuseNames -contains $name)
        foreach ($proc in @([Diagnostics.Process]::GetProcessesByName($name))) {
            try {
                try {
                    if ($proc.HasExited) { continue }
                } catch {}

                $image = Get-ProcessImagePathSafe $proc
                if ([string]::IsNullOrWhiteSpace($image)) {
                    $stillAlive = $true
                    try {
                        $check = [Diagnostics.Process]::GetProcessById($proc.Id)
                        $check.Dispose()
                    } catch {
                        $stillAlive = $false
                    }
                    if (-not $stillAlive) { continue }
                    if ($isAlwaysRefuse) {
                        throw "$FriendlyError（无法读取进程路径：$name.exe，PID $($proc.Id)）"
                    }
                    Write-Warning "检测到同名进程 $name.exe (PID $($proc.Id)) 但无法读取其路径，将继续执行；若文件被占用将自动回滚。"
                    continue
                }

                $fullImage = [IO.Path]::GetFullPath($image)
                foreach ($scope in $normalizedScopes) {
                    if ($fullImage.StartsWith($scope, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "$FriendlyError（$name.exe，PID $($proc.Id)）"
                    }
                }
            } finally {
                $proc.Dispose()
            }
        }
    }
}

function Assert-AllowedGameRelative([string]$Relative) {
    if ($Relative -eq 'resources.assets') { return }
    if ($Relative -notmatch '^(?:\.res/(?:raw_base_package|raw_streaming_package|default_package)/BundleFiles|StreamingAssets/\.res/(?:default_package|static_package))/[a-z0-9]+\.r$') {
        throw "不允许写入：$Relative"
    }
}

function Assert-GameResource([string]$Path, $Entry, [bool]$Patched) {
    $expected = if ($Patched) { $Entry.target_sha256 } else { $Entry.source_sha256 }
    $checkCrc = $Entry.relative_path.EndsWith('.r')
    $fullCrc = [uint32]0
    $segOffsets = $null
    $segSizes = $null
    $segCrcs = $null
    $segIds = $null

    if ($checkCrc) {
        $fullCrc = [uint32]$Entry.crc32
        $segs = @($Entry.segments)
        $segOffsets = New-Object 'long[]' $segs.Count
        $segSizes = New-Object 'long[]' $segs.Count
        $segCrcs = New-Object 'uint32[]' $segs.Count
        $segIds = New-Object 'int[]' $segs.Count
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $segOffsets[$i] = [long]$segs[$i].offset
            $segSizes[$i] = [long]$segs[$i].size
            $segCrcs[$i] = [uint32]$segs[$i].crc32
            $segIds[$i] = [int]$segs[$i].bundle_index
        }
    }

    [LocalizationNative]::VerifyFile(
        $Path,
        [long]$Entry.size,
        [string]$expected,
        $checkCrc,
        $fullCrc,
        $segOffsets,
        $segSizes,
        $segCrcs,
        $segIds
    )
}

function Replace-FileVerified([string]$Source, [string]$Target, [string]$ExpectedSha) {
    $temp = $Target + '.crc-zhcn-stage-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($Source, $temp, $false)
        if ((Get-FileSha256 $temp) -ne $ExpectedSha) {
            throw "暂存文件校验失败：$Target"
        }
        [IO.File]::Replace($temp, $Target, [System.Management.Automation.Language.NullString]::Value)
    } finally {
        if ([IO.File]::Exists($temp)) {
            try { [IO.File]::Delete($temp) } catch {}
        }
    }
}

function Test-ManifestSegmentsMatch($PackBundles, $ExpectedSegments) {
    $actual = @($PackBundles)
    $expected = @($ExpectedSegments)
    if ($actual.Count -ne $expected.Count) { return $false }
    $expSorted = @($expected | Sort-Object offset)
    for ($i = 0; $i -lt $actual.Count; $i++) {
        $a = $actual[$i]
        $e = $expSorted[$i]
        if ([int]$a.Index -ne [int]$e.bundle_index -or
            [long]$a.Offset -ne [long]$e.offset -or
            [long]$a.Size -ne [long]$e.size -or
            [uint32]$a.Crc -ne [uint32]$e.crc32) {
            return $false
        }
    }
    return $true
}

function Get-RelocatedPackState([string]$Path, $Item) {
    $segs = @($Item.AllSegments)
    $segOffsets = New-Object 'long[]' $segs.Count
    $segSizes = New-Object 'long[]' $segs.Count
    $segCrcs = New-Object 'uint32[]' $segs.Count
    $segIds = New-Object 'int[]' $segs.Count
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $segOffsets[$i] = [long]$segs[$i].offset
        $segSizes[$i] = [long]$segs[$i].size
        $segCrcs[$i] = [uint32]$segs[$i].crc32
        $segIds[$i] = [int]$segs[$i].bundle_index
    }
    [LocalizationNative]::VerifyFile(
        $Path,
        [long]$Item.Size,
        [string]$null,
        $true,
        [uint32]$Item.Crc32,
        $segOffsets,
        $segSizes,
        $segCrcs,
        $segIds
    )
    $patches = @($Item.SegmentPatches)
    $matchedTarget = 0
    $sourceMismatch = $false
    foreach ($patch in $patches) {
        $actualSha = [LocalizationNative]::ComputeRangeSha256($Path, [long]$patch.TargetOffset, [long]$patch.Size)
        if ([string]::Equals($actualSha, $patch.TargetSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $matchedTarget++
        } elseif ($patch.SourceSha256 -and -not [string]::Equals($actualSha, $patch.SourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $sourceMismatch = $true
        }
    }
    if ($matchedTarget -eq $patches.Count) { return 'Localized' }
    if ($matchedTarget -eq 0) {
        if ($sourceMismatch) { return 'Unknown' }
        return 'Original'
    }
    return 'Mixed'
}

function Resolve-GameDeploymentContext($Plan, [string]$DataDir) {
    $activeGuards = New-Object 'System.Collections.Generic.List[object]'
    $dynCandidates = @{}
    foreach ($g in @($Plan.readonly_files)) {
        if ($g.relative_path -match '^\.res/([^/]+)/ManifestFiles/0release_([^/]+)_(\d+)\.(bytes|hash)$' -and $Matches[1] -eq $Matches[2]) {
            $pkg = $Matches[1]
            $verStr = $Matches[3]
            $ext = $Matches[4]
            if (-not $dynCandidates.ContainsKey($pkg)) {
                $dynCandidates[$pkg] = @{
                    BaseVerStr = $verStr
                    BaseVer    = [long]$verStr
                    BytesGuard = $null
                    HashGuard  = $null
                    RawGuards  = (New-Object 'System.Collections.Generic.List[object]')
                }
            }
            $dc = $dynCandidates[$pkg]
            $dc.RawGuards.Add($g)
            if ($verStr -eq $dc.BaseVerStr) {
                if ($ext -eq 'bytes') { $dc.BytesGuard = $g } else { $dc.HashGuard = $g }
            }
        } else {
            $activeGuards.Add($g)
        }
    }

    $pkgState = @{}
    $hotfixVersions = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pkg in $dynCandidates.Keys) {
        $dc = $dynCandidates[$pkg]
        if (-not $dc.BytesGuard -or -not $dc.HashGuard -or $dc.RawGuards.Count -ne 2) {
            foreach ($rg in $dc.RawGuards) { $activeGuards.Add($rg) }
            continue
        }
        $manifestDirRel = ".res/$pkg/ManifestFiles"
        $manifestDir = Resolve-SafeChild $DataDir $manifestDirRel
        if (-not [IO.Directory]::Exists($manifestDir)) {
            throw "原版只读基线不匹配：$($dc.BytesGuard.relative_path)"
        }
        $pattern = '^0release_' + [regex]::Escape($pkg) + '_(\d+)\.bytes$'
        $maxVer = [long]-1
        $maxVerStr = $null
        foreach ($mf in @(Get-ChildItem -LiteralPath $manifestDir -File -ErrorAction SilentlyContinue)) {
            if ($mf.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($mf.Name -match $pattern) {
                $v = [long]$Matches[1]
                if ($v -gt $maxVer) {
                    $maxVer = $v
                    $maxVerStr = $Matches[1]
                }
            }
        }
        if ($maxVer -lt 0) {
            throw "原版只读基线不匹配：$($dc.BytesGuard.relative_path)"
        }
        if ($maxVer -lt $dc.BaseVer) {
            throw "原版只读基线版本过低：$($dc.BytesGuard.relative_path)"
        }
        if ($maxVer -eq $dc.BaseVer) {
            $activeGuards.Add($dc.BytesGuard)
            $activeGuards.Add($dc.HashGuard)
            $pkgState[$pkg] = @{ Mode = 'Exact'; Version = $maxVerStr; Manifest = $null }
        } else {
            $liveBytesRel = ".res/$pkg/ManifestFiles/0release_${pkg}_${maxVerStr}.bytes"
            $liveHashRel = ".res/$pkg/ManifestFiles/0release_${pkg}_${maxVerStr}.hash"
            $liveBytesPath = Resolve-SafeChild $DataDir $liveBytesRel
            $liveHashPath = Resolve-SafeChild $DataDir $liveHashRel
            if (-not [IO.File]::Exists($liveBytesPath)) { throw "原版只读基线缺失：$liveBytesRel" }
            if (-not [IO.File]::Exists($liveHashPath)) { throw "原版只读基线缺失：$liveHashRel" }
            $manifest = [LocalizationManifest]::ParseManifest($liveBytesPath, $liveHashPath)
            if ($manifest.Package -ne $pkg -or $manifest.Version -ne $maxVerStr) {
                throw "清单包名或版本不匹配：$liveBytesRel"
            }
            $activeGuards.Add([pscustomobject]@{ relative_path = $liveBytesRel; sha256 = (Get-FileSha256 $liveBytesPath) })
            $activeGuards.Add([pscustomobject]@{ relative_path = $liveHashRel; sha256 = (Get-FileSha256 $liveHashPath) })
            $pkgState[$pkg] = @{ Mode = 'Hotfix'; Version = $maxVerStr; Manifest = $manifest }
            if (-not $hotfixVersions.Contains($maxVerStr)) { $hotfixVersions.Add($maxVerStr) }
        }
    }

    $resolvedItems = New-Object 'System.Collections.Generic.List[object]'
    $relocatedOrder = New-Object 'System.Collections.Generic.List[string]'
    $relocatedMap = @{}
    foreach ($e in @($Plan.files)) {
        $useExact = $true
        if ($e.relative_path -match '^\.res/([^/]+)/BundleFiles/([^/]+)$') {
            $pkg = $Matches[1]
            $packName = $Matches[2]
            if ($pkgState.ContainsKey($pkg) -and $pkgState[$pkg].Mode -eq 'Hotfix') {
                $st = $pkgState[$pkg]
                $manifest = $st.Manifest
                $matchedPack = [LocalizationManifest]::FindPackByName($manifest, $packName)
                $packBundles = if ($matchedPack) {
                    @([LocalizationManifest]::GetPackBundles($manifest, $matchedPack.PackIndex))
                } else { @() }
                if ($matchedPack -and $matchedPack.Size -eq [long]$e.size -and $matchedPack.Crc -eq [uint32]$e.crc32 -and (Test-ManifestSegmentsMatch $packBundles $e.segments)) {
                    $useExact = $true
                } else {
                    $useExact = $false
                    $patchedSegs = $null
                    if ($e.PSObject.Properties.Name -contains 'patched_segments' -and $e.patched_segments) {
                        $patchedSegs = @($e.patched_segments)
                    } elseif (@($e.segments).Count -eq 1) {
                        $s0 = $e.segments[0]
                        $patchedSegs = @([pscustomobject]@{
                            bundle_index = $s0.bundle_index
                            offset = $s0.offset
                            size = $s0.size
                            crc32 = $s0.crc32
                            target_sha256 = $e.target_sha256
                            source_sha256 = $e.source_sha256
                        })
                    } else {
                        throw "部署清单缺少分段补丁信息，无法在热更版本 $($st.Version) 下定位：$($e.relative_path)"
                    }
                    foreach ($ps in $patchedSegs) {
                        $cands = @([LocalizationManifest]::FindBundles($manifest, [long]$ps.size, [uint32]$ps.crc32))
                        if ($cands.Count -eq 0) {
                            throw "热更版本 $($st.Version) 已修改目标资源段（bundle $($ps.bundle_index)），需要新版汉化补丁：$($e.relative_path)"
                        }
                        if ($cands.Count -gt 1) {
                            $narrow = @($cands | Where-Object { $_.Index -eq [int]$ps.bundle_index })
                            if ($narrow.Count -ne 1) {
                                throw "热更版本 $($st.Version) 中目标资源段匹配不唯一（bundle $($ps.bundle_index)），拒绝写入：$($e.relative_path)"
                            }
                            $cands = $narrow
                        }
                        $mb = $cands[0]
                        $targetPack = $manifest.Packs[$mb.PackId]
                        $newRel = ".res/$pkg/BundleFiles/$($targetPack.Name)"
                        Assert-AllowedGameRelative $newRel
                        if (-not $relocatedMap.ContainsKey($newRel)) {
                            $allPackBundles = @([LocalizationManifest]::GetPackBundles($manifest, $targetPack.PackIndex))
                            $allSegs = New-Object 'System.Collections.Generic.List[object]'
                            foreach ($ab in $allPackBundles) {
                                $allSegs.Add([pscustomobject]@{
                                    bundle_index = $ab.Index
                                    offset = $ab.Offset
                                    size = $ab.Size
                                    crc32 = $ab.Crc
                                })
                            }
                            $relocatedOrder.Add($newRel)
                            $relocatedMap[$newRel] = @{
                                Package = $pkg
                                ManifestVersion = $st.Version
                                TargetRelativePath = $newRel
                                PayloadRelativePath = $e.relative_path
                                Size = [long]$targetPack.Size
                                Crc32 = [uint32]$targetPack.Crc
                                AllSegments = @($allSegs.ToArray())
                                SegmentPatches = (New-Object 'System.Collections.Generic.List[object]')
                                BaselineEntries = (New-Object 'System.Collections.Generic.List[object]')
                                SeenTargetOffsets = (New-Object 'System.Collections.Generic.HashSet[long]')
                            }
                        }
                        $grp = $relocatedMap[$newRel]
                        if (-not $grp.SeenTargetOffsets.Add([long]$mb.Offset)) {
                            throw "热更版本 $($st.Version) 中目标段偏移冲突：$newRel"
                        }
                        $srcSegSha = $null
                        if ($ps.PSObject.Properties.Name -contains 'source_sha256' -and $ps.source_sha256) {
                            $srcSegSha = [string]$ps.source_sha256
                        } elseif (@($e.segments).Count -eq 1 -and [long]$ps.offset -eq 0 -and [long]$ps.size -eq [long]$e.size) {
                            $srcSegSha = [string]$e.source_sha256
                        }
                        $grp.SegmentPatches.Add([PSCustomObject]@{
                            BundleIndex = [int]$ps.bundle_index
                            TargetOffset = [long]$mb.Offset
                            PayloadOffset = [long]$ps.offset
                            Size = [long]$ps.size
                            Crc32 = [uint32]$ps.crc32
                            TargetSha256 = [string]$ps.target_sha256
                            SourceSha256 = $srcSegSha
                            PayloadRelativePath = $e.relative_path
                            BaselineEntry = $e
                        })
                        $alreadyBaseline = $false
                        foreach ($be in $grp.BaselineEntries) {
                            if ($be.relative_path -eq $e.relative_path) { $alreadyBaseline = $true; break }
                        }
                        if (-not $alreadyBaseline) { $grp.BaselineEntries.Add($e) }
                    }
                }
            }
        }
        if ($useExact) {
            $resolvedItems.Add([PSCustomObject]@{
                Mode = 'ExactFile'
                Package = $null
                ManifestVersion = $null
                TargetRelativePath = $e.relative_path
                PayloadRelativePath = $e.relative_path
                Entry = $e
            })
        }
    }
    foreach ($newRel in $relocatedOrder) {
        $grp = $relocatedMap[$newRel]
        $resolvedItems.Add([PSCustomObject]@{
            Mode = 'RelocatedSegments'
            Package = $grp.Package
            ManifestVersion = $grp.ManifestVersion
            TargetRelativePath = $grp.TargetRelativePath
            PayloadRelativePath = $grp.PayloadRelativePath
            Size = $grp.Size
            Crc32 = $grp.Crc32
            AllSegments = $grp.AllSegments
            SegmentPatches = @($grp.SegmentPatches.ToArray())
            BaselineEntries = @($grp.BaselineEntries.ToArray())
        })
    }

    return [PSCustomObject]@{
        ActiveGuards = @($activeGuards.ToArray())
        Items = @($resolvedItems.ToArray())
        HotfixVersions = @($hotfixVersions.ToArray())
    }
}

function Invoke-GameCRCZH {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Hint = '',
        [bool]$HintExplicit = $false,
        [string]$ToolsDir,
        [string]$PackRoot
    )

    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

    $planPath = Join-Path $ToolsDir $Config.DeploymentFile
    if (-not [IO.File]::Exists($planPath) -and $Config.FallbackDeploymentFile) {
        $fallbackPlan = Join-Path $ToolsDir $Config.FallbackDeploymentFile
        if ([IO.File]::Exists($fallbackPlan)) { $planPath = $fallbackPlan }
    }
    Assert-NoReparse $planPath
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($plan.region -ne $Config.Region) {
        throw "部署清单区域必须为 $($Config.Region)。"
    }

    $seen = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $plan.files) {
        Assert-AllowedGameRelative $e.relative_path
        if ($seen.ContainsKey($e.relative_path)) { throw "重复资源路径：$($e.relative_path)" }
        $seen[$e.relative_path] = $true
    }
    foreach ($g in $plan.readonly_files) {
        if ($seen.ContainsKey($g.relative_path)) { throw "只读路径与资源重叠或重复：$($g.relative_path)" }
        $seen[$g.relative_path] = $true
    }

    if ($Action -eq 'ValidatePayload') {
        $payloadRoot = Join-Path $PackRoot $Config.PayloadSubdir
        if (-not [IO.Directory]::Exists($payloadRoot)) {
            throw "补丁载荷目录不存在：$payloadRoot（请下载 Releases 完整包，勿直接下载源码 ZIP）"
        }
        foreach ($e in $plan.files) {
            Assert-GameResource (Resolve-SafeChild $payloadRoot $e.relative_path) $e $true
            Write-Host ('载荷通过：' + $e.relative_path)
        }
        Write-Host '全部载荷通过：大小、SHA256、整包 CRC、全部段 CRC。' -ForegroundColor Green
        return 0
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($HintExplicit) {
        if ([string]::IsNullOrWhiteSpace($Hint)) { throw '显式 Hint 不得为空。' }
        $h = [IO.Path]::GetFullPath($Hint.Trim().Trim('"'))
        if ([IO.File]::Exists($h)) { $h = Split-Path $h -Parent }
        $candidates.Add($h)
        if ((Split-Path $h -Leaf) -eq $Config.DataDirName) { $candidates.Add((Split-Path $h -Parent)) }
        foreach ($rel in $Config.HintRelatives) {
            $candidates.Add((Join-Path $h $rel))
        }
    } else {
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
            foreach ($rel in $Config.SearchRelatives) {
                $candidates.Add((Join-Path $drive.RootDirectory.FullName $rel))
            }
        }
    }

    $root = $null
    foreach ($c in $candidates) {
        try {
            if ([IO.File]::Exists((Join-Path $c $Config.ExeName)) -and [IO.Directory]::Exists((Join-Path $c $Config.DataDirName))) {
                $root = [IO.Path]::GetFullPath($c)
                break
            }
        } catch {}
    }
    if (-not $root) { throw $Config.NotFoundMsg }

    Assert-NoReparse $root
    $data = Join-Path $root $Config.DataDirName
    Assert-NoReparse $data
    $backup = Join-Path $root $Config.BackupDirName

    if ($Action -eq 'Menu') {
        Write-Host "$($Config.MenuTitle)`n$root"
        Write-Host '1 汉化   2 还原   3 完整校验   其他退出'
        switch ((Read-Host '选择').Trim()) {
            '1' { $Action = 'Apply' }
            '2' { $Action = 'Restore' }
            '3' { $Action = 'Verify' }
            default { return 0 }
        }
    }

    $ctx = Resolve-GameDeploymentContext $plan $data
    $assertGuards = {
        foreach ($g in $ctx.ActiveGuards) {
            $gp = Resolve-SafeChild $data $g.relative_path
            if (-not [IO.File]::Exists($gp) -or (Get-FileSha256 $gp) -ne $g.sha256) {
                throw "原版只读基线不匹配：$($g.relative_path)"
            }
        }
    }

    & $assertGuards

    if ($Action -eq 'Verify') {
        foreach ($item in $ctx.Items) {
            if ($item.Mode -eq 'ExactFile') {
                $e = $item.Entry
                $p = Resolve-SafeChild $data $e.relative_path
                if (-not [IO.File]::Exists($p)) { throw "文件缺失：$($e.relative_path)" }
                $hash = Get-FileSha256 $p
                if ($hash -eq $e.target_sha256) { Assert-GameResource $p $e $true; $state = '汉化' }
                elseif ($hash -eq $e.source_sha256) { Assert-GameResource $p $e $false; $state = '原版' }
                else { throw "文件既非原版也非本版汉化：$($e.relative_path)" }
                Write-Host ("通过 [$state] " + $e.relative_path)
            } else {
                $p = Resolve-SafeChild $data $item.TargetRelativePath
                if (-not [IO.File]::Exists($p)) { throw "文件缺失：$($item.TargetRelativePath)" }
                $relState = Get-RelocatedPackState $p $item
                if ($relState -eq 'Localized') { $state = "汉化 (热更适配 $($item.ManifestVersion))" }
                elseif ($relState -eq 'Original') { $state = "原版 (热更适配 $($item.ManifestVersion))" }
                else { throw "文件既非原版也非本版汉化：$($item.TargetRelativePath)" }
                Write-Host ("通过 [$state] " + $item.TargetRelativePath)
            }
        }
        Write-Host '完整校验通过，所有只读基线保持原字节。' -ForegroundColor Green
        return 0
    }

    $parentDir = Split-Path $root -Parent
    $launcherScopes = @($root)
    $parentRoot = if ($parentDir) { [IO.Path]::GetPathRoot($parentDir).TrimEnd('\') } else { '' }
    if ($parentDir -and -not [string]::Equals($parentDir.TrimEnd('\'), $parentRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $launcherScopes += $parentDir
    } elseif ($parentDir -and $Config.LauncherSiblingDirs) {
        foreach ($sib in $Config.LauncherSiblingDirs) {
            $launcherScopes += (Join-Path $parentDir $sib)
        }
    }

    $launcherAlwaysRefuse = if ($Config.LauncherProcName -ne 'launcher') { @($Config.LauncherProcName) } else { @() }
    $assertAllStopped = {
        Assert-ProcessesStopped -ProcessNames @($Config.GameProcName, 'sdkbrowser') -PathScopes @($root) -FriendlyError '请先完全退出游戏和登录窗口' -AlwaysRefuseNames @($Config.GameProcName)
        Assert-ProcessesStopped -ProcessNames @($Config.LauncherProcName) -PathScopes $launcherScopes -FriendlyError "请先完全退出关联启动器：$($Config.LauncherProcName).exe" -AlwaysRefuseNames $launcherAlwaysRefuse
    }

    & $assertAllStopped

    $payloadRoot = if ($Action -eq 'Apply') { Join-Path $PackRoot $Config.PayloadSubdir } else { $null }
    if ($Action -eq 'Apply' -and -not [IO.Directory]::Exists($payloadRoot)) {
        throw "补丁载荷目录不存在：$payloadRoot（请下载 Releases 完整包，勿直接下载源码 ZIP）"
    }

    $todo = New-Object 'System.Collections.Generic.List[object]'
    $needBackupBytes = [long]0
    $maxSingleStageBytes = [long]0
    $needSnapBytes = [long]0

    foreach ($item in $ctx.Items) {
        if ($item.Mode -eq 'ExactFile') {
            $e = $item.Entry
            $p = Resolve-SafeChild $data $e.relative_path
            if (-not [IO.File]::Exists($p)) { throw "游戏文件缺失：$($e.relative_path)" }
            $h = Get-FileSha256 $p
            if ($h -ne $e.source_sha256 -and $h -ne $e.target_sha256) {
                throw "文件版本不匹配：$($e.relative_path)"
            }
            $bk = Resolve-SafeChild $backup $e.relative_path
            $needsNewBackup = $false
            if ($Action -eq 'Apply') {
                $src = Resolve-SafeChild $payloadRoot $e.relative_path
                Assert-GameResource $src $e $true
                if (-not [IO.File]::Exists($bk)) {
                    if ($h -ne $e.source_sha256) { throw "缺少原版备份：$($e.relative_path)" }
                    $needsNewBackup = $true
                    $needBackupBytes += [long]$e.size
                } else {
                    if ((Get-FileSha256 $bk) -ne $e.source_sha256) { throw "原版备份不匹配：$bk" }
                }
                if ($h -eq $e.target_sha256) { continue }
                $exp = $e.target_sha256
            } else {
                if ($h -eq $e.source_sha256) { continue }
                Assert-GameResource $bk $e $false
                $src = $bk
                $exp = $e.source_sha256
            }

            if ([long]$e.size -gt $maxSingleStageBytes) { $maxSingleStageBytes = [long]$e.size }
            $reuseBackupAsSnap = ($Action -eq 'Apply' -and $h -eq $e.source_sha256)
            if (-not $reuseBackupAsSnap) { $needSnapBytes += [long]$e.size }
            $todo.Add([PSCustomObject]@{
                WriteKind         = 'Exact'
                Item              = $item
                Entry             = $e
                RelativePath      = $e.relative_path
                Target            = $p
                Source            = $src
                Expected          = $exp
                ExpectedBackupSha = $e.source_sha256
                Before            = $h
                Backup            = $bk
                NeedsNewBackup    = $needsNewBackup
                ReuseBackupAsSnap = $reuseBackupAsSnap
                Snap              = $null
                DonorPaths        = $null
                TargetOffsets     = $null
                DonorOffsets      = $null
                Sizes             = $null
                ExpectedState     = $null
            })
            continue
        }

        $p = Resolve-SafeChild $data $item.TargetRelativePath
        if (-not [IO.File]::Exists($p)) { throw "游戏文件缺失：$($item.TargetRelativePath)" }
        $relState = Get-RelocatedPackState $p $item
        if ($relState -notin @('Original', 'Localized')) {
            throw "文件版本不匹配：$($item.TargetRelativePath)"
        }
        $beforeSha = Get-FileSha256 $p
        $bk = Resolve-SafeChild $backup $item.TargetRelativePath
        $needsNewBackup = $false
        $writeKind = $null
        $src = $null
        $exp = $null
        $donorPaths = $null
        $targetOffsets = $null
        $donorOffsets = $null
        $sizes = $null
        $expectedState = $null

        if ($Action -eq 'Apply') {
            foreach ($be in $item.BaselineEntries) {
                $pay = Resolve-SafeChild $payloadRoot $be.relative_path
                Assert-GameResource $pay $be $true
            }
            if ([IO.File]::Exists($bk)) {
                try {
                    if ((Get-RelocatedPackState $bk $item) -ne 'Original') { throw '状态异常' }
                } catch {
                    throw "原版备份不匹配：$bk"
                }
            } elseif ($relState -eq 'Localized') {
                foreach ($be in $item.BaselineEntries) {
                    $legacyBk = Resolve-SafeChild $backup $be.relative_path
                    if (-not [IO.File]::Exists($legacyBk)) { throw "缺少原版备份：$($item.TargetRelativePath)" }
                    try {
                        Assert-GameResource $legacyBk $be $false
                    } catch {
                        throw "原版备份不匹配：$legacyBk"
                    }
                }
            } else {
                $needsNewBackup = $true
                $needBackupBytes += [long]$item.Size
            }
            if ($relState -eq 'Localized') { continue }

            [string[]]$donorPaths = @($item.SegmentPatches | ForEach-Object { Resolve-SafeChild $payloadRoot $_.PayloadRelativePath })
            [long[]]$targetOffsets = @($item.SegmentPatches | ForEach-Object { [long]$_.TargetOffset })
            [long[]]$donorOffsets = @($item.SegmentPatches | ForEach-Object { [long]$_.PayloadOffset })
            [long[]]$sizes = @($item.SegmentPatches | ForEach-Object { [long]$_.Size })
            $writeKind = 'RelocatedBuild'
            $expectedState = 'Localized'
        } else {
            if ($relState -eq 'Original') { continue }
            if ([IO.File]::Exists($bk)) {
                try {
                    if ((Get-RelocatedPackState $bk $item) -ne 'Original') { throw '状态异常' }
                } catch {
                    throw "原版备份不匹配：$bk"
                }
                $src = $bk
                $exp = Get-FileSha256 $bk
                $writeKind = 'RelocatedDirect'
                $expectedState = 'Original'
            } else {
                foreach ($be in $item.BaselineEntries) {
                    $legacyBk = Resolve-SafeChild $backup $be.relative_path
                    if (-not [IO.File]::Exists($legacyBk)) { throw "缺少原版备份：$($item.TargetRelativePath)" }
                    try {
                        Assert-GameResource $legacyBk $be $false
                    } catch {
                        throw "原版备份不匹配：$legacyBk"
                    }
                }
                [string[]]$donorPaths = @($item.SegmentPatches | ForEach-Object { Resolve-SafeChild $backup $_.PayloadRelativePath })
                [long[]]$targetOffsets = @($item.SegmentPatches | ForEach-Object { [long]$_.TargetOffset })
                [long[]]$donorOffsets = @($item.SegmentPatches | ForEach-Object { [long]$_.PayloadOffset })
                [long[]]$sizes = @($item.SegmentPatches | ForEach-Object { [long]$_.Size })
                $writeKind = 'RelocatedBuild'
                $expectedState = 'Original'
            }
        }

        if ([long]$item.Size -gt $maxSingleStageBytes) { $maxSingleStageBytes = [long]$item.Size }
        $reuseBackupAsSnap = ($Action -eq 'Apply' -and $relState -eq 'Original')
        if (-not $reuseBackupAsSnap) { $needSnapBytes += [long]$item.Size }
        $todo.Add([PSCustomObject]@{
            WriteKind         = $writeKind
            Item              = $item
            Entry             = $null
            RelativePath      = $item.TargetRelativePath
            Target            = $p
            Source            = $src
            Expected          = $exp
            ExpectedBackupSha = $beforeSha
            Before            = $beforeSha
            Backup            = $bk
            NeedsNewBackup    = $needsNewBackup
            ReuseBackupAsSnap = $reuseBackupAsSnap
            Snap              = $null
            DonorPaths        = $donorPaths
            TargetOffsets     = $targetOffsets
            DonorOffsets      = $donorOffsets
            Sizes             = $sizes
            ExpectedState     = $expectedState
        })
    }

    if ($todo.Count -eq 0) {
        Write-Host '所有文件均已处于目标状态，无需修改。' -ForegroundColor Green
        return 0
    }

    Assert-FreeDiskSpace $root ($needBackupBytes + $needSnapBytes + $maxSingleStageBytes)

    # Clean up any leftover staging files on target paths before beginning.
    foreach ($w in $todo) {
        $tDir = Split-Path $w.Target -Parent
        $tLeaf = Split-Path $w.Target -Leaf
        foreach ($stale in @(Get-ChildItem -LiteralPath $tDir -Filter ($tLeaf + '.crc-zhcn-stage-*') -Force -ErrorAction SilentlyContinue)) {
            if (-not ($stale.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                try { [IO.File]::Delete($stale.FullName) } catch {}
            }
        }
    }

    # Create verified original backups only for entries being touched (or missing backups).
    foreach ($w in $todo) {
        if ($w.NeedsNewBackup) {
            [IO.Directory]::CreateDirectory((Split-Path $w.Backup -Parent)) | Out-Null
            [IO.File]::Copy($w.Target, $w.Backup, $false)
            if ((Get-FileSha256 $w.Backup) -ne $w.ExpectedBackupSha) {
                throw "原版备份校验失败：$($w.Backup)"
            }
            if ($w.Item.Mode -eq 'RelocatedSegments' -and (Get-RelocatedPackState $w.Backup $w.Item) -ne 'Original') {
                throw "原版备份校验失败：$($w.Backup)"
            }
        }
    }

    $txParent = Join-Path $backup 'transactions'
    $snapdir = $null
    $preserveSnap = $false
    foreach ($w in $todo) {
        if ($w.ReuseBackupAsSnap) {
            $w.Snap = $w.Backup
        } else {
            if (-not $snapdir) {
                $snapdir = Join-Path $txParent ([Guid]::NewGuid().ToString('N'))
            }
            $sp = Resolve-SafeChild $snapdir $w.RelativePath
            [IO.Directory]::CreateDirectory((Split-Path $sp -Parent)) | Out-Null
            [IO.File]::Copy($w.Target, $sp, $false)
            if ((Get-FileSha256 $sp) -ne $w.Before) { throw '操作前快照验证失败。' }
            $w.Snap = $sp
        }
    }

    $done = New-Object 'System.Collections.Generic.List[object]'
    try {
        try {
            & $assertAllStopped
            & $assertGuards
            foreach ($w in $todo) {
                if ((Get-FileSha256 $w.Target) -ne $w.Before) { throw '操作期间目标文件发生变化。' }
                if ($w.WriteKind -eq 'Exact') {
                    Replace-FileVerified $w.Source $w.Target $w.Expected
                    $done.Add($w)
                    Assert-GameResource $w.Target $w.Entry ($Action -eq 'Apply')
                } elseif ($w.WriteKind -eq 'RelocatedDirect') {
                    Replace-FileVerified $w.Source $w.Target $w.Expected
                    $done.Add($w)
                    if ((Get-RelocatedPackState $w.Target $w.Item) -ne $w.ExpectedState) {
                        throw "写入后校验失败：$($w.RelativePath)"
                    }
                } else {
                    $temp = $w.Target + '.crc-zhcn-stage-' + [Guid]::NewGuid().ToString('N')
                    try {
                        [LocalizationManifest]::BuildPatchedPack($w.Target, $w.DonorPaths, $w.TargetOffsets, $w.DonorOffsets, $w.Sizes, $temp) | Out-Null
                        if ((Get-RelocatedPackState $temp $w.Item) -ne $w.ExpectedState) {
                            throw "暂存文件校验失败：$($w.Target)"
                        }
                        [IO.File]::Replace($temp, $w.Target, [System.Management.Automation.Language.NullString]::Value)
                    } finally {
                        if ([IO.File]::Exists($temp)) {
                            try { [IO.File]::Delete($temp) } catch {}
                        }
                    }
                    $done.Add($w)
                    if ((Get-RelocatedPackState $w.Target $w.Item) -ne $w.ExpectedState) {
                        throw "写入后校验失败：$($w.RelativePath)"
                    }
                }
                Write-Host ('已写入并校验：' + $w.RelativePath)
            }
            & $assertGuards
        } catch {
            $reason = $_.Exception.Message
            $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
            for ($i = $done.Count - 1; $i -ge 0; $i--) {
                $w = $done[$i]
                try {
                    if ((Get-FileSha256 $w.Target) -ne $w.Before) {
                        Replace-FileVerified $w.Snap $w.Target $w.Before
                    }
                    if ((Get-FileSha256 $w.Target) -ne $w.Before) {
                        throw '回滚后哈希不匹配'
                    }
                } catch {
                    $rollbackErrors.Add(($w.Target + ': ' + $_.Exception.Message))
                }
            }
            if ($rollbackErrors.Count -gt 0) {
                $preserveSnap = $true
                $snapHint = if ($snapdir) { "（恢复快照位于：$snapdir）" } else { '' }
                throw ("操作失败：$reason；以下文件回滚失败，请保留原版备份与事务快照并手工恢复${snapHint}：" + ($rollbackErrors -join '；'))
            }
            throw "已回滚到操作前：$reason"
        }
    } finally {
        if (-not $preserveSnap -and $snapdir -and [IO.Directory]::Exists($snapdir)) {
            try {
                [IO.Directory]::Delete($snapdir, $true)
                if ([IO.Directory]::Exists($txParent) -and @(Get-ChildItem -LiteralPath $txParent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    [IO.Directory]::Delete($txParent, $false)
                }
            } catch {}
        }
    }

    Write-Host "$Action 完成。资源大小、段 CRC、整包 CRC 和只读基线均通过。" -ForegroundColor Green
    return 0
}

