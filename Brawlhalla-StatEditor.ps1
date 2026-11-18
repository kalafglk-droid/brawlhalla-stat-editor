# Brawlhalla SWZ Stat Editor (v6)
# Edits hero stats (Strength / Dexterity / Defense / Speed) inside Game.swz.
# The game requires every hero's 4 stats to add up to 22 and caps each at 11. When you go beyond that, the tool patches BrawlhallaAir.swf.
# Dexterity and Speed can go up to 100 (extra stat rows are added). Strength and Defense stay 0-11 (the game's damage table only covers that range),
# but separate Strength and Defense multipliers (up to 100,000) amplify how much Strength-minus-Defense changes damage and knockback.
# Separate Dexterity and Speed multipliers (up to 100,000) set how strong those two stats get at level 100.
# OFFLINE / TRAINING ROOM USE ONLY: start the game with -noeac and never go online with modified files.
# Originals are kept next to the files as *.statbackup. "Restore original" puts them back.

$ErrorActionPreference = 'Stop'

# ---------- self update (GitHub) ----------
# Bump $ScriptVersion on every release. The published version.json (same folder as this file on GitHub) holds the newest number, its notes and the SHA256 of the script.
$ScriptVersion = 3  # dev build: per-hero instant test
$UpdateBase = 'https://raw.githubusercontent.com/kalafglk-droid/brawlhalla-stat-editor/dev'

# ---------- self-elevate (the Steam folder usually needs admin to write) ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class SwzFile
{
    public uint Key;
    public uint Seed;
    public List<byte[]> Chunks = new List<byte[]>();
}

public static class Swz
{
    // WELL512-style generator used by Brawlhalla's SWZ container.
    private class Prng
    {
        private uint[] s = new uint[16];
        private int idx;

        public void Init(uint seed)
        {
            s[0] = seed;
            idx = 0;
            for (int i = 1; i < 16; i++)
            {
                uint p = s[i - 1];
                s[i] = (uint)i + 1812433253u * (p ^ (p >> 30));
            }
        }

        public uint Next()
        {
            uint a = s[idx];
            uint b = s[(idx - 3) & 15];
            uint c = a ^ b ^ ((b ^ (2u * a)) << 15);
            uint e = s[(idx - 7) & 15];
            uint d = (e >> 11) ^ e;
            int n = (idx - 1) & 15;
            s[idx] = d ^ c;
            s[n] ^= d ^ (32u * ((d ^ c) & 0xfed22169u)) ^ (4u * (s[n] ^ ((c ^ (d << 10)) << 16)));
            idx = n;
            return s[n];
        }
    }

    private static uint BE(byte[] d, int o)
    {
        return ((uint)d[o] << 24) | ((uint)d[o + 1] << 16) | ((uint)d[o + 2] << 8) | (uint)d[o + 3];
    }

    private static void PutBE(Stream o, uint v)
    {
        o.WriteByte((byte)(v >> 24));
        o.WriteByte((byte)(v >> 16));
        o.WriteByte((byte)(v >> 8));
        o.WriteByte((byte)v);
    }

    private static uint Rotr(uint x, int n)
    {
        n &= 31;
        if (n == 0) return x;
        return (x >> n) | (x << (32 - n));
    }

    private static uint HeaderChecksum(Prng p, uint key, uint seed)
    {
        p.Init(seed);
        uint cs = 771006925u;
        int n = (int)(key % 31u) + 5;
        for (int i = 0; i < n; i++) cs ^= p.Next();
        return cs;
    }

    private static byte[] Inflate(byte[] z)
    {
        using (MemoryStream ms = new MemoryStream(z, 2, z.Length - 2))
        using (DeflateStream ds = new DeflateStream(ms, CompressionMode.Decompress))
        using (MemoryStream outp = new MemoryStream())
        {
            byte[] buf = new byte[65536];
            int r;
            while ((r = ds.Read(buf, 0, buf.Length)) > 0) outp.Write(buf, 0, r);
            return outp.ToArray();
        }
    }

    private static byte[] Deflate(byte[] raw)
    {
        using (MemoryStream ms = new MemoryStream())
        {
            ms.WriteByte(0x78);
            ms.WriteByte(0x9C);
            using (DeflateStream ds = new DeflateStream(ms, CompressionMode.Compress, true))
            {
                ds.Write(raw, 0, raw.Length);
            }
            uint a = 1, b = 0;
            for (int i = 0; i < raw.Length; i++)
            {
                a = (a + raw[i]) % 65521u;
                b = (b + a) % 65521u;
            }
            PutBE(ms, (b << 16) | a);
            return ms.ToArray();
        }
    }

    // ---- SWF patch: raises the hard-coded stat cap (11) inside BrawlhallaAir.swf ----
    private static readonly string[] SwfPatterns = new string[] {
        "747363086208240b74af12060000",
        "74af12060000240b747363086207",
        "747363096209240b74af12060000",
        "74af12060000240b747363096207",
        "7473630a620a240b74af12060000",
        "74af12060000240b7473630a6207",
        "7473630b620b240b74af12060000",
        "74af12060000240b7473630b60c1",
        "2e620866e209240b74af122f0000",
        "01620866d902240b74af122f0000",
        "01620866bc63240b74af122f0000",
        "016208668d2e240b74af122e0000",
        "072400736308240b742401c57473",
        "1207000029d2240b74ae76121c00"
    };

    // Damage/knockback multipliers indexed by (attacker Strength - defender Defense), -11..+11 (centre value 1.0 is not in the list).
    private static readonly double[] TableVals = new double[] {
        0.8349, 0.8384, 0.8437, 0.851, 0.8604, 0.8719, 0.8857, 0.9022, 0.9215, 0.9439, 0.9699,
        1.031, 1.0594, 1.0852, 1.1084, 1.129, 1.1469, 1.1623, 1.1751, 1.1853, 1.1928, 1.1978
    };

    // Stat budget check in the hero loader: "sum of the 4 stats must be 0 or 22". Replaced by: pop; pushfalse; nop x7 (same length, same stack effect).
    private const string BudgetFind = "961209000029620d241674ab967612280000";
    private const string BudgetRepl = "961209000029270202020202020212280000";

    private static byte[] FromHex(string h)
    {
        byte[] b = new byte[h.Length / 2];
        for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(h.Substring(i * 2, 2), 16);
        return b;
    }

    private static int IndexOfBytes(byte[] data, byte[] pat, int start)
    {
        int last = data.Length - pat.Length;
        for (int i = start; i <= last; i++)
        {
            if (data[i] != pat[0]) continue;
            int j = 1;
            while (j < pat.Length && data[i + j] == pat[j]) j++;
            if (j == pat.Length) return i;
        }
        return -1;
    }

    private static bool IsSig(byte[] swf, char a)
    {
        return swf.Length > 8 && swf[0] == (byte)a && swf[1] == (byte)'W' && swf[2] == (byte)'S';
    }

    public static byte[] SwfBody(byte[] swf)
    {
        byte[] b = new byte[swf.Length - 8];
        Buffer.BlockCopy(swf, 8, b, 0, b.Length);
        if (IsSig(swf, 'C')) return Inflate(b);
        if (IsSig(swf, 'F')) return b;
        throw new InvalidDataException("Unsupported SWF format");
    }

    // Returns a patched copy of the SWF: the cap of 11 becomes 'level' (11..127) for Dexterity/Speed, the "stats must add up to 22" check is disabled,
    // and the Strength-minus-Defense damage/knockback table is amplified around 1.0 (ampStr for Strength's side, ampDef for Defense's side; 1 = untouched).
    public static byte[] PatchSwf(byte[] swf, int level, double ampStr, double ampDef)
    {
        if (level < 11 || level > 127) throw new ArgumentException("level must be between 11 and 127");
        byte[] body = SwfBody(swf);
        int[] at = new int[SwfPatterns.Length];
        for (int i = 0; i < SwfPatterns.Length; i++)
        {
            byte[] pat = FromHex(SwfPatterns[i]);
            int p = IndexOfBytes(body, pat, 0);
            if (p < 0) throw new InvalidDataException("BrawlhallaAir.swf does not match the expected code (game updated?). Pattern " + i + " not found.");
            if (IndexOfBytes(body, pat, p + 1) >= 0) throw new InvalidDataException("Pattern " + i + " is ambiguous.");
            at[i] = p + 7;
        }
        byte[] bFind = FromHex(BudgetFind);
        byte[] bRepl = FromHex(BudgetRepl);
        int bp = IndexOfBytes(body, bFind, 0);
        if (bp < 0) throw new InvalidDataException("BrawlhallaAir.swf does not match the expected code (stat budget check not found).");
        if (IndexOfBytes(body, bFind, bp + 1) >= 0) throw new InvalidDataException("Stat budget pattern is ambiguous.");
        int[] tp = new int[TableVals.Length];
        for (int i = 0; i < TableVals.Length; i++)
        {
            byte[] dp = BitConverter.GetBytes(TableVals[i]);
            int q = IndexOfBytes(body, dp, 0);
            if (q < 0) throw new InvalidDataException("BrawlhallaAir.swf does not match the expected code (damage table value " + i + " not found).");
            if (IndexOfBytes(body, dp, q + 1) >= 0) throw new InvalidDataException("Damage table value " + i + " is ambiguous.");
            tp[i] = q;
        }
        // Patterns 0,1 (Strength) and 4,5 (Defense) in the entity loader keep their cap of 11: those two stats index the damage table.
        for (int i = 0; i < at.Length; i++)
        {
            if (i == 0 || i == 1 || i == 4 || i == 5) continue;
            body[at[i]] = (byte)level;
        }
        Buffer.BlockCopy(bRepl, 0, body, bp, bRepl.Length);
        for (int i = 0; i < tp.Length; i++)
        {
            bool defenderSide = i < 11;   // entries 0..10 = Defense beats Strength, 11..21 = Strength beats Defense
            double k = defenderSide ? ampDef : ampStr;
            if (k <= 1.0001) continue;
            double nv = 1.0 + (TableVals[i] - 1.0) * k;
            if (nv < 0.001) nv = 0.001;   // 0 would mean "no scaling" to the game, so stay just above it
            Buffer.BlockCopy(BitConverter.GetBytes(nv), 0, body, tp[i], 8);
        }
        byte[] payload = IsSig(swf, 'C') ? Deflate(body) : body;
        byte[] outp = new byte[8 + payload.Length];
        Buffer.BlockCopy(swf, 0, outp, 0, 8);
        Buffer.BlockCopy(payload, 0, outp, 8, payload.Length);
        return outp;
    }

    public static bool HeaderOk(byte[] data, uint key)
    {
        if (data.Length < 8) return false;
        Prng p = new Prng();
        uint seed = BE(data, 4) ^ key;
        return HeaderChecksum(p, key, seed) == BE(data, 0);
    }

    public static SwzFile Read(byte[] data, uint key)
    {
        if (data.Length < 8) throw new InvalidDataException("File too small");
        uint expected = BE(data, 0);
        uint seed = BE(data, 4) ^ key;
        Prng p = new Prng();
        if (HeaderChecksum(p, key, seed) != expected) throw new InvalidDataException("Wrong key (header checksum mismatch)");

        SwzFile f = new SwzFile();
        f.Key = key;
        f.Seed = seed;
        int off = 8;
        while (data.Length - off > 12)
        {
            uint csz = BE(data, off) ^ p.Next();
            uint usz = BE(data, off + 4) ^ p.Next();
            uint ecs = BE(data, off + 8);
            off += 12;
            if (csz > (uint)(data.Length - off)) throw new InvalidDataException("Bad chunk size");
            uint c = p.Next();
            byte[] buf = new byte[csz];
            for (int i = 0; i < (int)csz; i++)
            {
                uint r = p.Next();
                int bi = i & 15;
                byte nb = (byte)(data[off + i] ^ (((0xffu << bi) & r) >> bi));
                buf[i] = nb;
                c = (uint)nb ^ Rotr(c, (i % 7) + 1);
            }
            off += (int)csz;
            if (c != ecs) throw new InvalidDataException("Chunk checksum mismatch");
            f.Chunks.Add(Inflate(buf));
        }
        return f;
    }

    public static byte[] Write(List<byte[]> chunks, uint key, uint seed)
    {
        Prng p = new Prng();
        uint cs0 = HeaderChecksum(p, key, seed);
        using (MemoryStream o = new MemoryStream())
        {
            PutBE(o, cs0);
            PutBE(o, seed ^ key);
            foreach (byte[] raw in chunks)
            {
                byte[] comp = Deflate(raw);
                PutBE(o, (uint)comp.Length ^ p.Next());
                PutBE(o, (uint)raw.Length ^ p.Next());
                uint c = p.Next();
                byte[] body = new byte[comp.Length];
                for (int i = 0; i < comp.Length; i++)
                {
                    uint r = p.Next();
                    int bi = i & 15;
                    body[i] = (byte)(comp[i] ^ (((0xffu << bi) & r) >> bi));
                    c = (uint)comp[i] ^ Rotr(c, (i % 7) + 1);
                }
                PutBE(o, c);
                o.Write(body, 0, body.Length);
            }
            return o.ToArray();
        }
    }

    // Shrinks the recovery time (FixedRecoverTime and the first number of RecoverTime) of every attack in the powerTypes table.
    // keep = 1 leaves it untouched, 0 removes recovery completely. Works on raw bytes (Latin-1) so nothing else changes.
    // Taunts (any row whose name contains "taunt") are left alone.
    // Also shrinks the attack cooldowns (CooldownTime, OnHitCooldownTime = the wait before the next attack) and the minimum charge time (FixedMinChargeTime),
    // each with its own keep value (1 = untouched, 0 = removed). Taunt rows are skipped for all of them.
    // "Tail" = the wait steps at the END of an attack's CastTime list (no damage, no impulse): the move is already over but the character is still held.
    // keepTail scales the tick number of those steps (1 = untouched). Nix's scythe Down Light (ScytheDownHit* rows, a grab in 3 stages) has no damage list that
    // lines up with its CastTime, so every step after the first one in those rows is treated as tail. For all other attacks the tail starts after the last step that deals damage.
    private static string[] SplitList(string v, out bool quoted)
    {
        quoted = v.Length >= 2 && v[0] == '"' && v[v.Length - 1] == '"';
        string inner = quoted ? v.Substring(1, v.Length - 2) : v;
        return inner.Split(',');
    }

    private static int LastDamageIndex(string cast, string dmg)
    {
        if (cast.Length == 0 || dmg.Length == 0) return -1;
        bool q1, q2;
        string[] c = SplitList(cast, out q1);
        string[] d = SplitList(dmg, out q2);
        if (c.Length != d.Length) return -1;
        int last = -1;
        for (int i = 0; i < d.Length; i++)
        {
            string x = d[i].Trim();
            if (x.Length > 0 && x != "0") last = i;
        }
        return last;
    }

    private static string ScaleCastFrom(string v, int from, double keep)
    {
        bool quoted;
        string[] parts = SplitList(v, out quoted);
        for (int i = from; i < parts.Length; i++)
        {
            string e = parts[i];
            int at = e.IndexOf('@');
            string head = at >= 0 ? e.Substring(0, at) : e;
            string tail = at >= 0 ? e.Substring(at) : "";
            int colon = head.IndexOf(':');
            string num = colon >= 0 ? head.Substring(0, colon) : head;
            string cnt = colon >= 0 ? head.Substring(colon) : "";
            if (num.Length == 0 || num.Length > 9) continue;
            bool digits = true;
            for (int z = 0; z < num.Length; z++) if (num[z] < '0' || num[z] > '9') { digits = false; break; }
            if (!digits) continue;
            long n = long.Parse(num);
            long nn = (long)Math.Floor(n * keep + 1e-9);
            if (n > 0 && nn < 1) nn = 1;
            parts[i] = nn.ToString() + cnt + tail;
        }
        string joined = string.Join(",", parts);
        return quoted ? "\"" + joined + "\"" : joined;
    }

    public static byte[] ScaleRecover(byte[] chunk, double keepRec, double keepCd, double keepChg, double keepTail, string weapons)
    {
        // weapons: "|Scythe|Pistol|" style list of ParentItem names to limit the change to those weapons' attacks; empty = every attack.
        Encoding L1 = Encoding.GetEncoding(28591);
        string t = L1.GetString(chunk);
        int nl = t.IndexOf('\n');
        if (nl < 0 || !t.StartsWith("powerTypes")) throw new Exception("powerTypes table not recognised.");

        // pass 1: split the table into rows (quote aware)
        List<List<string>> rows = new List<List<string>>();
        List<string> terms = new List<string>();
        int p = nl + 1;
        while (p < t.Length)
        {
            List<string> f = new List<string>();
            StringBuilder cur = new StringBuilder();
            bool q = false;
            int i = p;
            for (; i < t.Length; i++)
            {
                char c = t[i];
                if (c == '"') { q = !q; cur.Append(c); }
                else if (c == ',' && !q) { f.Add(cur.ToString()); cur.Length = 0; }
                else if (c == '\n' && !q) break;
                else cur.Append(c);
            }
            f.Add(cur.ToString());
            terms.Add(i < t.Length ? "\n" : "");
            rows.Add(f);
            p = i + 1;
        }
        if (rows.Count < 2) throw new Exception("powerTypes table is empty.");

        // header: which columns to scale
        List<string> hdr = rows[0];
        int ncols = hdr.Count;
        int a = -1, b = -1, nameCol = 0, castCol = -1, dmgCol = -1, parentCol = -1, originCol = -1;
        List<int> cl = new List<int>();
        List<double> kl = new List<double>();
        for (int k = 0; k < hdr.Count; k++)
        {
            string nm = hdr[k].Trim();
            if (nm == "FixedRecoverTime") { a = k; cl.Add(k); kl.Add(keepRec); }
            if (nm == "RecoverTime") { b = k; cl.Add(k); kl.Add(keepRec); }
            if (nm == "CooldownTime" || nm == "OnHitCooldownTime") { cl.Add(k); kl.Add(keepCd); }
            if (nm == "FixedMinChargeTime") { cl.Add(k); kl.Add(keepChg); }
            if (nm == "PowerName") nameCol = k;
            if (nm == "CastTime") castCol = k;
            if (nm == "BaseDamage") dmgCol = k;
            if (nm == "ParentItem") parentCol = k;
            if (nm == "OriginPower") originCol = k;
        }
        if (a < 0 || b < 0) throw new Exception("Recovery columns not found.");
        int[] cols = cl.ToArray();
        double[] keeps = kl.ToArray();

        // Only the attacks of the 15 real weapons and unarmed are touched. Items, bombs, thrown weapons, spawn bots, game-mode weapons
        // (zombie, odd ball, folding chair) and taunts keep their timing: they are not hero attacks, and changing them can freeze a match.
        const string allowed = "|Sword|Hammer|Pistol|RocketLance|Spear|Katar|Axe|Bow|Fists|Scythe|Cannon|Orb|Greatsword|Boots|Chakram|Unarmed|";
        bool scoped = weapons != null && weapons.Length > 0;
        if (parentCol < 0 || originCol < 0) throw new Exception("Weapon columns not found in the attack table.");
        Dictionary<string, string> parentOf = new Dictionary<string, string>();
        Dictionary<string, string> originOf = new Dictionary<string, string>();
        for (int r = 1; r < rows.Count; r++)
        {
            List<string> f = rows[r];
            if (f.Count != ncols) continue;
            parentOf[f[nameCol]] = f[parentCol].Trim();
            originOf[f[nameCol]] = f[originCol].Trim();
        }

        // pass 2: scale
        StringBuilder o = new StringBuilder(t.Length);
        o.Append(t, 0, nl + 1);
        for (int r = 0; r < rows.Count; r++)
        {
            List<string> f = rows[r];
            if (r > 0 && f.Count == ncols && f[nameCol].IndexOf("taunt", StringComparison.OrdinalIgnoreCase) < 0)
            {
                bool inScope;
                {
                    // the weapon of a row is its ParentItem, or that of the attack it comes from (OriginPower)
                    string w = f[parentCol].Trim();
                    string on = f[originCol].Trim();
                    int hops = 0;
                    while (w.Length == 0 && on.Length > 0 && hops < 10)
                    {
                        string pw;
                        string po;
                        if (!parentOf.TryGetValue(on, out pw)) break;
                        originOf.TryGetValue(on, out po);
                        w = pw;
                        on = po == null ? "" : po;
                        hops++;
                    }
                    inScope = w.Length > 0 && allowed.IndexOf("|" + w + "|", StringComparison.Ordinal) >= 0;
                    if (inScope && scoped) inScope = weapons.IndexOf("|" + w + "|", StringComparison.Ordinal) >= 0;
                }
                if (inScope)
                {
                    for (int k = 0; k < cols.Length; k++)
                    {
                        string v = f[cols[k]];
                        int at = v.IndexOf('@');
                        string num = at >= 0 ? v.Substring(0, at) : v;
                        string rest = at >= 0 ? v.Substring(at) : "";
                        if (num.Length == 0 || num.Length > 9) continue;
                        bool digits = true;
                        for (int z = 0; z < num.Length; z++) if (num[z] < '0' || num[z] > '9') { digits = false; break; }
                        if (!digits) continue;
                        long n = long.Parse(num);
                        long nn = (long)Math.Floor(n * keeps[k] + 1e-9);
                        if (n > 0 && nn < 1) nn = 1;
                        f[cols[k]] = nn.ToString() + rest;
                    }
                    if (keepTail < 0.9999 && castCol >= 0)
                    {
                        if (f[nameCol].StartsWith("ScytheDownHit", StringComparison.Ordinal))
                            f[castCol] = ScaleCastFrom(f[castCol], 1, keepTail);
                        else if (dmgCol >= 0)
                        {
                            int lastDmg = LastDamageIndex(f[castCol], f[dmgCol]);
                            if (lastDmg >= 0) f[castCol] = ScaleCastFrom(f[castCol], lastDmg + 1, keepTail);
                        }
                    }
                }
            }
            o.Append(string.Join(",", f.ToArray()));
            o.Append(terms[r]);
        }
        return L1.GetBytes(o.ToString());
    }

    public static byte[] WriteReplacing(SwzFile f, int index, byte[] replacement)
    {
        List<byte[]> list = new List<byte[]>(f.Chunks);
        list[index] = replacement;
        return Write(list, f.Key, f.Seed);
    }

    public static bool TryRead(byte[] data, uint key)
    {
        try { Read(data, key); return true; }
        catch (Exception) { return false; }
    }

    // Full 32-bit key search (only used if the game was updated and the known key no longer fits).
    public static long FindKey(byte[] data)
    {
        uint expected = BE(data, 0);
        uint sw = BE(data, 4);
        long found = -1;
        const long block = 1L << 22;
        long nb = (1L << 32) / block;
        Parallel.For(0L, nb, delegate(long b, ParallelLoopState state)
        {
            if (Interlocked.Read(ref found) >= 0) { state.Stop(); return; }
            Prng p = new Prng();
            long start = b * block;
            long end = start + block;
            for (long k = start; k < end; k++)
            {
                uint key = (uint)k;
                if (HeaderChecksum(p, key, sw ^ key) == expected)
                {
                    if (TryRead(data, key))
                    {
                        Interlocked.CompareExchange(ref found, k, -1);
                        state.Stop();
                        return;
                    }
                }
            }
        });
        return found;
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp

$KnownKey = [uint32]154281100
$enc = New-Object System.Text.UTF8Encoding($false)
$NormalMax = 11     # what the unpatched game allows
$InstantLevel = 10  # Dexterity level used by INSTANT HIT (11 made the hero vanish in Couch Party)
$NormalTotal = 22   # the unpatched game requires the 4 stats of a hero to add up to this
$ExtMax = 100       # highest level in extended mode (must be 12..127)
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# Value each effect reaches at level $ExtMax (levels 12..$ExtMax are interpolated from the original level-11 value).
# Effects not listed here keep their level-11 value. Edit freely, then press "Write to game" again.
$ExtTargets = @{
    ImpulseMult = 4.0
    RecoverMod = 4.0; AirRecoverMod = 4.0; SigRecoverMod = 4.0; MinChargeMod = 4.0
    Recovery = 14.0
}
# Speed effects are scaled relative to their level-11 value (set from the Speed field when you write).
$ExtScale = @{
    RunSpeed = 2.0; AnimSpeed = 2.0; Acceleration = 2.0; Friction = 2.0
    AirRunSpeed = 2.0; AirAcceleration = 2.0; AirFriction = 2.0
}

$InstantHeroes = @{}   # heroes with INSTANT HIT switched on (name -> display name)
$InstantBackup = @{}   # what each of them had staged before (to put back when switched off)
$script:globalBackup = $null

function Get-UpdateInfo {
    if ($UpdateBase -match 'OWNER') { return $null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -UseBasicParsing -Uri ("$UpdateBase/version.json?t=" + [DateTime]::UtcNow.Ticks) -TimeoutSec 8
    $j = ([string]$r.Content).Trim([char]0xFEFF) | ConvertFrom-Json
    if ([int]$j.version -gt $ScriptVersion) { return $j }
    return $null
}

function Show-Msg($text, $title = 'Brawlhalla Stat Editor', $icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon)
}

# ---------- locate game folder ----------
function Find-GameDir {
    $cands = @()
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\Brawlhalla') }
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'Steam\steamapps\common\Brawlhalla') }
    foreach ($d in 'C', 'D', 'E', 'F', 'G') {
        $cands += "${d}:\SteamLibrary\steamapps\common\Brawlhalla"
        $cands += "${d}:\Steam\steamapps\common\Brawlhalla"
    }
    foreach ($c in $cands) { if (Test-Path -LiteralPath (Join-Path $c 'Game.swz')) { return $c } }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the Brawlhalla folder (the one containing Game.swz)'
    if ($dlg.ShowDialog() -eq 'OK' -and (Test-Path -LiteralPath (Join-Path $dlg.SelectedPath 'Game.swz'))) { return $dlg.SelectedPath }
    return $null
}

$GameDir = Find-GameDir
if (-not $GameDir) { Show-Msg 'Could not find Game.swz. Run again and select your Brawlhalla folder.' 'Error' 'Error'; exit 1 }
$GameSwz   = Join-Path $GameDir 'Game.swz'
$Backup    = Join-Path $GameDir 'Game.swz.statbackup'
$StateF    = Join-Path $GameDir 'Game.swz.statstate'
$SwfPath   = Join-Path $GameDir 'BrawlhallaAir.swf'
$SwfBackup = Join-Path $GameDir 'BrawlhallaAir.swf.statbackup'
$SwfState  = Join-Path $GameDir 'BrawlhallaAir.swf.statstate'
$HasSwf    = Test-Path -LiteralPath $SwfPath

function Get-Sha1($p) { (Get-FileHash -Algorithm SHA1 -LiteralPath $p).Hash }

# ---------- backup logic ----------
function Ensure-Backup($path, $bak, $state, $what) {
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $path -Destination $bak
        if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state }
        return
    }
    $cur = Get-Sha1 $path
    $b = Get-Sha1 $bak
    $st = if (Test-Path -LiteralPath $state) { (Get-Content -LiteralPath $state -Raw).Trim() } else { '' }
    if ($cur -ne $b -and $cur -ne $st) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "$what is different from both the backup and the last file this tool wrote.`n`nThe game was probably updated. Use the current file as the new original?",
            "$what changed", 'YesNo', 'Question')
        if ($r -eq 'Yes') {
            Copy-Item -LiteralPath $path -Destination $bak -Force
            if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state }
        }
    }
}
Ensure-Backup $GameSwz $Backup $StateF 'Game.swz'
if ($HasSwf) { Ensure-Backup $SwfPath $SwfBackup $SwfState 'BrawlhallaAir.swf' }

# ---------- decrypt the ORIGINAL (backup) ----------
$origBytes = [System.IO.File]::ReadAllBytes($Backup)
$key = $KnownKey
if (-not [Swz]::HeaderOk($origBytes, $key)) {
    Write-Host 'Known key does not fit (game updated?). Searching all 2^32 keys - this can take a few minutes...'
    $k = [Swz]::FindKey($origBytes)
    if ($k -lt 0) { Show-Msg 'Could not find the decryption key for this Game.swz. The file format may have changed.' 'Error' 'Error'; exit 1 }
    $key = [uint32]$k
    Write-Host "Found key: $key"
}
$swz = [Swz]::Read($origBytes, $key)

$heroIdx = -1
$runeIdx = -1
$statIdx = -1
$powerIdx = -1
for ($i = 0; $i -lt $swz.Chunks.Count; $i++) {
    $c = $swz.Chunks[$i]
    if ($c.Length -gt 12) {
        $head = $enc.GetString($c, 0, 11)
        if ($heroIdx -lt 0 -and $head -eq '<HeroTypes>') { $heroIdx = $i }
        if ($runeIdx -lt 0 -and $head.StartsWith('<RuneTypes>')) { $runeIdx = $i }
        if ($statIdx -lt 0 -and $head.StartsWith('<StatTypes>')) { $statIdx = $i }
        if ($powerIdx -lt 0 -and $head.StartsWith('powerTypes')) { $powerIdx = $i }
    }
}
if ($heroIdx -lt 0) { Show-Msg 'HeroTypes section not found in Game.swz.' 'Error' 'Error'; exit 1 }
$origText = $enc.GetString($swz.Chunks[$heroIdx])
$runeOrig = if ($runeIdx -ge 0) { $enc.GetString($swz.Chunks[$runeIdx]) } else { '' }
$statOrig = if ($statIdx -ge 0) { $enc.GetString($swz.Chunks[$statIdx]) } else { '' }

# self-test: re-encrypting the untouched file must read back identically
$test = [Swz]::Read([Swz]::WriteReplacing($swz, $heroIdx, $swz.Chunks[$heroIdx]), $key)
if ($test.Chunks.Count -ne $swz.Chunks.Count -or $enc.GetString($test.Chunks[$heroIdx]) -ne $origText) {
    Show-Msg 'Self-test failed. Nothing will be written.' 'Error' 'Error'; exit 1
}

# can we use extended levels? (needs the swf, the stat table, and the known code patterns)
$ExtOk = $false
$ExtWhy = ''
if (-not $HasSwf) { $ExtWhy = 'BrawlhallaAir.swf not found.' }
elseif ($statIdx -lt 0) { $ExtWhy = 'StatTypes table not found.' }
else {
    try {
        $swfOrigBytes = [System.IO.File]::ReadAllBytes($SwfBackup)
        [void][Swz]::PatchSwf($swfOrigBytes, $ExtMax, 1.0, 1.0)
        $ExtOk = $true
    } catch { $ExtWhy = $_.Exception.Message }
}
$UiMax = if ($ExtOk) { $ExtMax } else { $NormalMax }
$StatMax = @{ Strength = $NormalMax; Dexterity = $UiMax; Weight = $NormalMax; Speed = $UiMax }

# ---------- parse heroes ----------
$StatNames = @('Strength', 'Dexterity', 'Weight', 'Speed')
$blockRx = New-Object System.Text.RegularExpressions.Regex('<HeroType HeroName="([^"]*)">(.*?)</HeroType>', 'Singleline')
$runeRx = New-Object System.Text.RegularExpressions.Regex('<RuneType><HeroName>([^<]*)</HeroName><RuneIndex>0</RuneIndex><Strength>\d+</Strength><Dexterity>\d+</Dexterity><Weight>\d+</Weight><Speed>\d+</Speed>')
$Heroes = New-Object System.Collections.ArrayList
foreach ($m in $blockRx.Matches($origText)) {
    $b = $m.Groups[2].Value
    $vals = @{}
    $ok = $true
    foreach ($s in $StatNames) {
        $mm = [regex]::Match($b, "<$s>(\d+)</$s>")
        if ($mm.Success) { $vals[$s] = [int]$mm.Groups[1].Value } else { $ok = $false }
    }
    if (-not $ok) { continue }
    $dn = [regex]::Match($b, '<HeroDisplayName>([^<]*)</HeroDisplayName>')
    $id = [regex]::Match($b, '<HeroID>(\d+)</HeroID>')
    if ($id.Success -and [int]$id.Groups[1].Value -lt 3) { continue }
    $disp = if ($dn.Success) { [System.Net.WebUtility]::HtmlDecode($dn.Groups[1].Value) } else { $m.Groups[1].Value }
    [void]$Heroes.Add([pscustomobject]@{ Name = $m.Groups[1].Value; Display = $disp; Orig = $vals })
}
$Heroes = @($Heroes | Sort-Object Display)
$Staged = @{}   # HeroName -> hashtable of the 4 stats (only when different from original)

# ---------- build / write ----------
function Build-HeroText {
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in $blockRx.Matches($origText)) {
        $name = $m.Groups[1].Value
        $block = $m.Value
        if ($Staged.ContainsKey($name)) {
            $v = $Staged[$name]
            foreach ($s in $StatNames) {
                $val = [int]$v[$s]
                $block = [regex]::Replace($block, "<$s>\d+</$s>", "<$s>$val</$s>")
            }
        }
        [void]$sb.Append($origText.Substring($pos, $m.Index - $pos))
        [void]$sb.Append($block)
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($origText.Substring($pos))
    return $sb.ToString()
}

# keep the "base stance" rows (RuneIndex 0) in sync with the hero stats - the game reads its stats from here
function Build-RuneText {
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in $runeRx.Matches($runeOrig)) {
        $name = $m.Groups[1].Value
        [void]$sb.Append($runeOrig.Substring($pos, $m.Index - $pos))
        if ($Staged.ContainsKey($name)) {
            $v = $Staged[$name]
            $sv = [string]$v['Strength']; $dx = [string]$v['Dexterity']; $wt = [string]$v['Weight']; $sp = [string]$v['Speed']
            [void]$sb.Append("<RuneType><HeroName>$name</HeroName><RuneIndex>0</RuneIndex><Strength>$sv</Strength><Dexterity>$dx</Dexterity><Weight>$wt</Weight><Speed>$sp</Speed>")
        } else {
            [void]$sb.Append($m.Value)
        }
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($runeOrig.Substring($pos))
    return $sb.ToString()
}

# extra StatType rows for levels 12..$ExtMax (Strength12 ... Speed100), interpolated from the level-11 row
function Build-StatText {
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $StatNames) {
        $m11 = [regex]::Match($statOrig, "<StatType StatName=""${s}11"">(.*?)</StatType>", 'Singleline')
        if (-not $m11.Success) { throw "Stat row ${s}11 not found." }
        $props = [regex]::Matches($m11.Groups[1].Value, '<(\w+)>([^<]*)</\1>')
        for ($lv = 12; $lv -le $ExtMax; $lv++) {
            $t = ($lv - 11) / ($ExtMax - 11)
            [void]$sb.Append("<StatType StatName=""$s$lv"">")
            foreach ($p in $props) {
                $pn = $p.Groups[1].Value
                $v0 = [double]::Parse($p.Groups[2].Value, $inv)
                if ($ExtScale.ContainsKey($pn)) { $v0 = $v0 + ($v0 * [double]$ExtScale[$pn] - $v0) * $t }
                elseif ($ExtTargets.ContainsKey($pn)) { $v0 = $v0 + ([double]$ExtTargets[$pn] - $v0) * $t }
                $vs = $v0.ToString('0.####', $inv)
                [void]$sb.Append("<$pn>$vs</$pn>")
            }
            [void]$sb.Append('</StatType>')
        }
    }
    $end = $statOrig.LastIndexOf('</StatTypes>')
    if ($end -lt 0) { throw 'StatTypes end tag not found.' }
    return $statOrig.Substring(0, $end) + $sb.ToString() + $statOrig.Substring($end)
}

# INSTANT HIT without the game patch: only the existing Dexterity level-11 row is boosted (no extra levels, no code patch).
# Every hero that has Dexterity 11 is affected, so INSTANT HIT gives its hero Dexterity 11 and the other stats are scaled to keep the total at 22.
function Build-StatTextLevel11($val) {
    $m = [regex]::Match($statOrig, ('<StatType StatName="Dexterity' + $InstantLevel + '">(.*?)</StatType>'), 'Singleline')
    if (-not $m.Success) { throw "Stat row Dexterity$InstantLevel not found." }
    $block = $m.Value
    $vs = ([double]$val).ToString('0.####', $inv)
    foreach ($k in 'RecoverMod', 'AirRecoverMod', 'SigRecoverMod', 'MinChargeMod') {
        $block = [regex]::Replace($block, "<$k>[^<]*</$k>", "<$k>$vs</$k>")
    }
    return $statOrig.Substring(0, $m.Index) + $block + $statOrig.Substring($m.Index + $m.Length)
}

# Cap = some value is above 11 (needs extra stat rows + raised cap); Budget = some hero's 4 stats do not add up to 22
function Get-Mode {
    $cap = $false; $bud = $false
    foreach ($v in $Staged.Values) {
        $sum = 0
        foreach ($s in $StatNames) {
            $x = [int]$v[$s]
            $sum += $x
            if ($x -gt $NormalMax) { $cap = $true }
        }
        if ($sum -ne $NormalTotal) { $bud = $true }
    }
    $amp = $false
    if ($strNum -and [double]$strNum.Value -gt 1) { $amp = $true }
    if ($defNum -and [double]$defNum.Value -gt 1) { $amp = $true }
    return @{ Cap = $cap; Budget = $bud; Amp = $amp }
}
function Needs-Ext {
    $m = Get-Mode
    return ($m.Cap -or $m.Budget -or $m.Amp)
}

function Write-Safe($dest, $bytes, $stateFile) {
    $tmp = $dest + '.new'
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    Copy-Item -LiteralPath $tmp -Destination $dest -Force
    Remove-Item -LiteralPath $tmp -Force
    Set-Content -LiteralPath $stateFile -Value (Get-Sha1 $dest)
}

function Restore-Swf {
    if ($HasSwf -and (Test-Path -LiteralPath $SwfBackup)) {
        Copy-Item -LiteralPath $SwfBackup -Destination $SwfPath -Force
        if (Test-Path -LiteralPath $SwfState) { Remove-Item -LiteralPath $SwfState -Force }
    }
}

function Restore-Original {
    Restore-Swf
    Copy-Item -LiteralPath $Backup -Destination $GameSwz -Force
    if (Test-Path -LiteralPath $StateF) { Remove-Item -LiteralPath $StateF -Force }
}

function Write-Game {
    try {
        $mode = Get-Mode
        $ext = ($mode.Cap -or $mode.Budget -or $mode.Amp)
        $ampS = if ($strNum) { [double]$strNum.Value } else { 1.0 }
        $ampD = if ($defNum) { [double]$defNum.Value } else { 1.0 }
        if ($ext -and -not $ExtOk) { throw "Dexterity/Speed above $NormalMax, totals other than $NormalTotal and the effect multiplier need the game patch, which is not available: $ExtWhy" }
        $newText = Build-HeroText
        $list = New-Object 'System.Collections.Generic.List[byte[]]'
        $list.AddRange($swz.Chunks)
        $list[$heroIdx] = $enc.GetBytes($newText)
        $newRune = ''
        if ($runeIdx -ge 0) {
            $newRune = Build-RuneText
            $list[$runeIdx] = $enc.GetBytes($newRune)
        }
        $keep = [double]$recNum.Value / 100.0
        $newPower = $null
        if ($keep -lt 0.9999) {
            if ($powerIdx -lt 0) { throw 'The attack data (powerTypes) was not found in Game.swz.' }
            $newPower = [Swz]::ScaleRecover($swz.Chunks[$powerIdx], $keep, $keep, $keep, $keep, '')
            $list[$powerIdx] = $newPower
        }
        $newStat = ''
        if ($mode.Cap) {
            $dp = [double]$dexNum.Value
            foreach ($k in 'RecoverMod', 'AirRecoverMod', 'SigRecoverMod', 'MinChargeMod') { $ExtTargets[$k] = $dp }
            $sp = [double]$spdNum.Value
            foreach ($k in 'RunSpeed', 'Acceleration', 'Friction', 'AirRunSpeed', 'AirAcceleration', 'AirFriction') { $ExtScale[$k] = $sp }
            $ExtScale['AnimSpeed'] = [double]$animNum.Value
            $newStat = Build-StatText
            $list[$statIdx] = $enc.GetBytes($newStat)
        } elseif ($InstantHeroes.Count -gt 0) {
            if ($statIdx -lt 0) { throw 'The stat table (StatTypes) was not found in Game.swz.' }
            $newStat = Build-StatTextLevel11 0.001   # DEV: marker value, read by the patched BrawlhallaAir.swf
            $list[$statIdx] = $enc.GetBytes($newStat)
        }
        $script:lastNote = ''
        if ($InstantHeroes.Count -gt 0) {
            $shared = @()
            foreach ($h in $Heroes) {
                if ($InstantHeroes.ContainsKey($h.Name)) { continue }
                $hv = if ($Staged.ContainsKey($h.Name)) { $Staged[$h.Name] } else { $h.Orig }
                if ([int]$hv['Dexterity'] -eq $InstantLevel) { $shared += $h.Display }
            }
            if ($shared.Count -gt 0) { $script:lastNote = " Also faster (they have the same Dexterity level too): $($shared -join ', ')." }
        }
        $newBytes = [Swz]::Write($list, $key, $swz.Seed)
        $chk = [Swz]::Read($newBytes, $key)
        if ($chk.Chunks.Count -ne $swz.Chunks.Count) { throw 'Verification of the new file failed (chunk count).' }
        if ($enc.GetString($chk.Chunks[$heroIdx]) -ne $newText) { throw 'Verification of the new file failed (hero data).' }
        if ($runeIdx -ge 0 -and $enc.GetString($chk.Chunks[$runeIdx]) -ne $newRune) { throw 'Verification of the new file failed (stance data).' }
        if ($newPower -ne $null -and [System.Convert]::ToBase64String($chk.Chunks[$powerIdx]) -ne [System.Convert]::ToBase64String($newPower)) { throw 'Verification of the new file failed (attack data).' }
        if ($newStat -ne '' -and $enc.GetString($chk.Chunks[$statIdx]) -ne $newStat) { throw 'Verification of the new file failed (stat table).' }

        if ($ext) {
            $lvl = if ($mode.Cap) { $ExtMax } else { $NormalMax }
            $swfNew = [Swz]::PatchSwf($swfOrigBytes, $lvl, $ampS, $ampD)
            $len0 = ([Swz]::SwfBody($swfOrigBytes)).Length
            $len1 = ([Swz]::SwfBody($swfNew)).Length
            if ($len0 -ne $len1) { throw 'Verification of the patched BrawlhallaAir.swf failed.' }
            # game data first (extra rows are harmless on their own), then the patched code
            Write-Safe $GameSwz $newBytes $StateF
            Write-Safe $SwfPath $swfNew $SwfState
        } else {
            # code back to original first, then the data
            Restore-Swf
            Write-Safe $GameSwz $newBytes $StateF
        }
        return $true
    } catch {
        Show-Msg ("Could not write the game files:`n" + $_.Exception.Message + "`n`nIs Brawlhalla still running? Close it and try again.") 'Error' 'Error'
        return $false
    }
}

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Brawlhalla Stat Editor v$ScriptVersion (offline / training only)"
$waH = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
$form.Size = New-Object System.Drawing.Size(760, ([Math]::Min(735, $waH)))
$form.AutoScroll = $true
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$tips = New-Object System.Windows.Forms.ToolTip
$tips.AutoPopDelay = 30000

$list = New-Object System.Windows.Forms.ListBox
$list.Location = New-Object System.Drawing.Point(12, 12)
$list.Size = New-Object System.Drawing.Size(240, 560)
$form.Controls.Add($list)

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(270, 12)
$title.Size = New-Object System.Drawing.Size(460, 28)
$title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

# hero stats
$labels = @{ Strength = 'Strength'; Dexterity = 'Dexterity'; Weight = 'Defense'; Speed = 'Speed' }
$bars = @{}; $nums = @{}
$y = 48
foreach ($s in $StatNames) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $labels[$s]; $l.Location = New-Object System.Drawing.Point(270, ($y + 8)); $l.Size = New-Object System.Drawing.Size(80, 22)
    $form.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TrackBar
    $t.Minimum = 0; $t.Maximum = $StatMax[$s]; $t.TickFrequency = $(if ($StatMax[$s] -gt 20) { 10 } else { 1 })
    $t.Location = New-Object System.Drawing.Point(350, $y); $t.Size = New-Object System.Drawing.Size(280, 45)
    $form.Controls.Add($t); $bars[$s] = $t
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 0; $n.Maximum = $StatMax[$s]
    $n.Location = New-Object System.Drawing.Point(645, ($y + 6)); $n.Size = New-Object System.Drawing.Size(80, 24)
    $form.Controls.Add($n); $nums[$s] = $n
    $y += 46
}
$totalLbl = New-Object System.Windows.Forms.Label
$totalLbl.Location = New-Object System.Drawing.Point(270, 234); $totalLbl.Size = New-Object System.Drawing.Size(460, 22)
$totalLbl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($totalLbl)
if ($ExtOk) {
    $tips.SetToolTip($totalLbl, "Normal game: the 4 stats add up to 22, max 11 each. Other totals, or Dexterity/Speed above 11 (up to $ExtMax), make the tool patch BrawlhallaAir.swf. Strength/Defense max is 11.")
} else {
    $tips.SetToolTip($totalLbl, "Range limited to 0-11: $ExtWhy")
}

# global values (hover a row for details)
function New-PowerRow($text, $y, $min, $max, $val, $tip) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(270, ($y + 4)); $l.Size = New-Object System.Drawing.Size(330, 22)
    $l.Text = $text
    $form.Controls.Add($l)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $min; $n.Maximum = $max; $n.DecimalPlaces = 0; $n.ThousandsSeparator = $true; $n.Value = $val
    $n.Location = New-Object System.Drawing.Point(610, $y); $n.Size = New-Object System.Drawing.Size(120, 24)
    $form.Controls.Add($n)
    $tips.SetToolTip($l, $tip); $tips.SetToolTip($n, $tip)
    return $n
}
$strNum  = New-PowerRow 'Strength multiplier' 266 1 100000 1 'Max 100,000 (1 = normal). Damage and knockback when your Strength beats their Defense.'
$defNum  = New-PowerRow 'Defense multiplier' 298 1 100000 1 'Max 100,000 (1 = normal). Less damage and knockback taken. Around 40+ already hits the minimum.'
$dexNum  = New-PowerRow 'Dexterity multiplier (level 100)' 330 1 1000000000 4 'Max 1,000,000,000 (4 = default). Levels 12-100 scale up to it; while INSTANT HIT is on it is applied to Dexterity 11 instead. Higher = shorter recovery.'
$spdNum  = New-PowerRow 'Speed multiplier (movement)' 362 1 1000000000 2 'Max 1,000,000,000 (2 = default). Run speed, acceleration, friction at level 100.'
$animNum = New-PowerRow 'Animation speed multiplier' 394 1 1000000000 2 'Max 1,000,000,000 (2 = default). Animation speed at level 100.'
$recNum  = New-PowerRow 'Attack delays kept % (ALL heroes)' 426 0 100 100 '100 = normal, 0 = none. Recovery, cooldown, minimum charge and the waits at the end of attacks. Attacks are stored per weapon, so every hero with the same weapons gets it. Taunts and items are never touched.'

function New-Btn($text, $x, $y, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 32)
    $form.Controls.Add($b); return $b
}
$btnReset    = New-Btn 'Reset this hero' 270 466 130
$btnAll      = New-Btn 'Copy to ALL heroes' 410 466 160
$btnResetAll = New-Btn 'Reset all' 580 466 150
$btnWrite    = New-Btn 'Write to game' 270 508 130
$btnRestore  = New-Btn 'Restore original' 410 508 160
$btnLaunch   = New-Btn 'Launch offline' 580 508 150
$tips.SetToolTip($btnAll, 'Stage these four stats for every hero (heroes with INSTANT HIT on keep theirs).')
$tips.SetToolTip($btnLaunch, 'Starts Brawlhalla through Steam with -noeac (offline).')

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(270, 552); $status.Size = New-Object System.Drawing.Size(460, 70)
$status.Text = "Game folder: $GameDir"
$form.Controls.Add($status)

# INSTANT HIT (left, under the hero list)
$btnInstant = New-Object System.Windows.Forms.CheckBox
$btnInstant.Appearance = [System.Windows.Forms.Appearance]::Button
$btnInstant.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$btnInstant.Location = New-Object System.Drawing.Point(12, 580); $btnInstant.Size = New-Object System.Drawing.Size(240, 52)
$btnInstant.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnInstant.Text = 'INSTANT HIT: OFF'
$form.Controls.Add($btnInstant)
$btnUpdate = New-Btn 'Check for updates' 12 642 240
$tips.SetToolTip($btnUpdate, 'Looks for a newer version of this tool on GitHub. It shows what changed and asks before replacing anything; the old file is kept next to it as .old')
$tips.SetToolTip($btnInstant, 'ON: this hero gets Dexterity 10 (its other stats are scaled to keep the total at 22) and the Dexterity multiplier goes to its maximum (locked). Needs no game patch. Any other hero that also has Dexterity 10 gets faster too. OFF: everything goes back.')

$script:loading = $false
function Current-Hero { if ($list.SelectedIndex -ge 0) { return $Heroes[$list.SelectedIndex] } return $null }

function Refresh-List {
    $sel = $list.SelectedIndex
    $list.Items.Clear()
    foreach ($h in $Heroes) {
        $mark = if ($Staged.ContainsKey($h.Name)) { '* ' } else { '  ' }
        [void]$list.Items.Add($mark + $h.Display)
    }
    if ($sel -ge 0 -and $sel -lt $list.Items.Count) { $list.SelectedIndex = $sel }
}

function Update-Total {
    $sum = 0
    foreach ($s in $StatNames) { $sum += [int]$nums[$s].Value }
    if ($sum -eq $NormalTotal) { $totalLbl.Text = "Total: $sum" }
    else { $totalLbl.Text = "Total: $sum (normal is $NormalTotal)" }
}

function Load-Controls {
    $h = Current-Hero
    if (-not $h) { return }
    $v = if ($Staged.ContainsKey($h.Name)) { $Staged[$h.Name] } else { $h.Orig }
    $script:loading = $true
    $title.Text = $h.Display
    foreach ($s in $StatNames) {
        $val = [Math]::Max(0, [Math]::Min([int]$StatMax[$s], [int]$v[$s]))
        $nums[$s].Value = [decimal]$val
        $bars[$s].Value = $val
    }
    $script:loading = $false
    Update-Total
    Update-InstantUI
}

# INSTANT HIT is a switch per hero. ON: that hero gets Dexterity 100 and the global values below are forced to their maximum and locked.
# OFF: the hero's earlier stats come back and, when no hero is left on, the locked values go back to what they were.
function Set-InstantOn($h) {
    if ($InstantHeroes.ContainsKey($h.Name)) { return }
    if ($InstantHeroes.Count -eq 0) {
        $script:globalBackup = @{ Dex = $dexNum.Value }
    }
    $base = if ($Staged.ContainsKey($h.Name)) { $Staged[$h.Name] } else { $h.Orig }
    $InstantBackup[$h.Name] = if ($Staged.ContainsKey($h.Name)) { $Staged[$h.Name].Clone() } else { $null }
    # legal stats only (max 11 each, total 22): Dexterity 11 and the other three scaled to share the remaining 11
    $v = $base.Clone()
    $v['Dexterity'] = $InstantLevel
    $rest = $NormalTotal - $InstantLevel
    $keys = @('Strength', 'Weight', 'Speed')
    $sum = 0
    foreach ($k in $keys) { $sum += [int]$base[$k] }
    $new = @{}
    if ($sum -le 0) { $new['Strength'] = 4; $new['Weight'] = 4; $new['Speed'] = 3 }
    else {
        $acc = 0
        foreach ($k in $keys) { $new[$k] = [int][Math]::Floor([int]$base[$k] * $rest / $sum); $acc += $new[$k] }
        $order = @($keys | Sort-Object { -[int]$base[$_] })
        $i = 0
        while ($acc -lt $rest) { $k = $order[$i % 3]; if ($new[$k] -lt $NormalMax) { $new[$k]++; $acc++ }; $i++ }
    }
    foreach ($k in $keys) { $v[$k] = $new[$k] }
    $Staged[$h.Name] = $v
    $InstantHeroes[$h.Name] = $h.Display
    $dexNum.Value = 1000     # Dexterity multiplier: high but not extreme (applied to the Dexterity 11 row)
}
function Set-InstantOff($name) {
    if (-not $InstantHeroes.ContainsKey($name)) { return }
    $b = $InstantBackup[$name]
    if ($b) { $Staged[$name] = $b } else { [void]$Staged.Remove($name) }
    $InstantHeroes.Remove($name)
    $InstantBackup.Remove($name)
    if ($InstantHeroes.Count -eq 0 -and $script:globalBackup) {
        $g = $script:globalBackup
        $dexNum.Value = $g.Dex
        $script:globalBackup = $null
    }
}
function Update-InstantUI {
    $h = Current-Hero
    $isInst = ($h -ne $null) -and $InstantHeroes.ContainsKey($h.Name)
    $anyInst = $InstantHeroes.Count -gt 0
    $script:syncing = $true
    $btnInstant.Checked = [bool]$isInst
    $script:syncing = $false
    $btnInstant.Text = if ($isInst) { "INSTANT HIT: ON`n(click to turn off)" } else { "INSTANT HIT: OFF`n(click to turn on for this hero)" }
    $bars['Dexterity'].Enabled = -not $isInst
    $nums['Dexterity'].Enabled = -not $isInst
    $dexNum.Enabled = $true   # stays editable so the INSTANT multiplier can be tuned
}

function Stage-FromControls {
    $h = Current-Hero
    if (-not $h) { return }
    $v = @{}
    $same = $true
    foreach ($s in $StatNames) {
        $v[$s] = [int]$nums[$s].Value
        if ($v[$s] -ne $h.Orig[$s]) { $same = $false }
    }
    if ($same) { $Staged.Remove($h.Name) } else { $Staged[$h.Name] = $v }
    $i = $list.SelectedIndex
    $mark = if ($Staged.ContainsKey($h.Name)) { '* ' } else { '  ' }
    $list.Items[$i] = $mark + $h.Display
    Update-Total
    $extNote = if (Needs-Ext) { ' (the game code will be patched on write)' } else { '' }
    $status.Text = "Staged changes: $($Staged.Count) hero(es). Press 'Write to game' to apply.$extNote"
}

foreach ($s in $StatNames) {
    $bars[$s].Add_ValueChanged({
        if ($script:loading) { return }
        $script:loading = $true
        foreach ($k in $StatNames) { $nums[$k].Value = [decimal]$bars[$k].Value }
        $script:loading = $false
        Stage-FromControls
    })
    $nums[$s].Add_ValueChanged({
        if ($script:loading) { return }
        $script:loading = $true
        foreach ($k in $StatNames) { $bars[$k].Value = [int]$nums[$k].Value }
        $script:loading = $false
        Stage-FromControls
    })
}

$list.Add_SelectedIndexChanged({ Load-Controls })

$btnReset.Add_Click({
    $h = Current-Hero; if (-not $h) { return }
    Set-InstantOff $h.Name
    [void]$Staged.Remove($h.Name); Refresh-List; Load-Controls
    $status.Text = "Staged changes: $($Staged.Count) hero(es)."
})
$btnResetAll.Add_Click({
    foreach ($n in @($InstantHeroes.Keys)) { Set-InstantOff $n }
    $Staged.Clear(); Refresh-List; Load-Controls
    $status.Text = 'All staged changes cleared (the game files are unchanged until you press Write).'
})
$btnAll.Add_Click({
    $vals = @{}
    foreach ($s in $StatNames) { $vals[$s] = [int]$nums[$s].Value }
    foreach ($h in $Heroes) {
        if ($InstantHeroes.ContainsKey($h.Name)) { continue }   # heroes with INSTANT HIT on keep their stats
        $same = $true
        foreach ($s in $StatNames) { if ($vals[$s] -ne $h.Orig[$s]) { $same = $false } }
        if ($same) { [void]$Staged.Remove($h.Name) } else { $Staged[$h.Name] = $vals.Clone() }
    }
    Refresh-List
    $status.Text = "Staged these stats for ALL heroes. Press 'Write to game' to apply."
})
$btnWrite.Add_Click({
    if ($Staged.Count -eq 0 -and [double]$strNum.Value -le 1 -and [double]$defNum.Value -le 1 -and [double]$recNum.Value -ge 100) {
        try {
            Restore-Original
            $status.Text = 'Nothing staged, so the original game files were put back.'
        } catch { Show-Msg ("Restore failed:`n" + $_.Exception.Message) 'Error' 'Error' }
        return
    }
    $wasExt = Needs-Ext
    $status.Text = 'Writing...'
    $form.Refresh()
    if (Write-Game) {
        $extDone = if ($wasExt) { ' BrawlhallaAir.swf was patched.' } else { '' }
        $status.Text = "Written. $($Staged.Count) hero(es) modified.$extDone$($script:lastNote) Start the game OFFLINE with -noeac."
    }
})
$btnInstant.Add_CheckedChanged({
    if ($script:syncing) { return }
    $h = Current-Hero
    if (-not $h) { Show-Msg 'Select a hero in the list first.' 'Instant hit' 'Warning'; Update-InstantUI; return }
    if ($btnInstant.Checked) {
        Set-InstantOn $h
    } else {
        Set-InstantOff $h.Name
    }
    Refresh-List; Load-Controls
    $btnWrite.PerformClick()
})
$btnRestore.Add_Click({
    try {
        Restore-Original
        foreach ($n in @($InstantHeroes.Keys)) { Set-InstantOff $n }
        $Staged.Clear(); $strNum.Value = 1; $defNum.Value = 1; $dexNum.Value = 4; $spdNum.Value = 2; $animNum.Value = 2; $recNum.Value = 100; Refresh-List; Load-Controls
        $status.Text = 'Original game files restored.'
    } catch { Show-Msg ("Restore failed:`n" + $_.Exception.Message) 'Error' 'Error' }
})
function Invoke-Update {
    try {
        if ($UpdateBase -match 'OWNER') { Show-Msg 'The update address is not set in this copy yet.' 'Update' 'Warning'; return }
        $j = Get-UpdateInfo
        if (-not $j) { Show-Msg "You already have the latest version (v$ScriptVersion)." 'Update'; return }
        $ans = [System.Windows.Forms.MessageBox]::Show("Version v$($j.version) is available (you have v$ScriptVersion).`n`n$([string]$j.notes)`n`nUpdate now? The tool will restart.", 'Update', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'Brawlhalla-StatEditor.new.ps1.tmp'
        Invoke-WebRequest -UseBasicParsing -Uri "$UpdateBase/Brawlhalla-StatEditor.ps1?t=$([DateTime]::UtcNow.Ticks)" -OutFile $tmp -TimeoutSec 60
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash
        if ($h -ne ([string]$j.sha256).ToUpper()) { Remove-Item -LiteralPath $tmp -Force; throw 'The downloaded file does not match the published checksum (the new version may still be uploading - try again in a few minutes). Nothing was changed.' }
        $tok = $null; $perr = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$perr)
        if ($perr -and $perr.Count -gt 0) { Remove-Item -LiteralPath $tmp -Force; throw 'The downloaded file is not a valid script. Nothing was changed.' }
        Copy-Item -LiteralPath $PSCommandPath -Destination ($PSCommandPath + '.old') -Force
        Copy-Item -LiteralPath $tmp -Destination $PSCommandPath -Force
        Remove-Item -LiteralPath $tmp -Force
        Show-Msg "Updated to v$($j.version). The tool will restart now." 'Update'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
        $form.Close()
    } catch { Show-Msg ("Update failed:`n" + $_.Exception.Message) 'Update' 'Error' }
}
$btnUpdate.Add_Click({ Invoke-Update })
$btnLaunch.Add_Click({
    try {
        Start-Process -FilePath 'steam://run/291550//-noeac/'
        $status.Text = 'Launch request sent to Steam with -noeac (offline). If Steam asks to confirm, accept. Do not play online with modified files.'
    } catch {
        Show-Msg ("Could not start the game through Steam:`n" + $_.Exception.Message + "`n`nStart it from Steam instead: Brawlhalla > Properties > Launch Options, type -noeac.") 'Error' 'Error'
    }
})

try {
    $u = Get-UpdateInfo
    if ($u) { $status.Text = "Update available: v$($u.version). Press 'Check for updates' (bottom left)."; $btnUpdate.Text = 'UPDATE AVAILABLE - click here' }
} catch { }
Refresh-List
if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
[void]$form.ShowDialog()
