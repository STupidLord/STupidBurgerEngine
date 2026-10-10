using System.Diagnostics;

namespace Burger.Runtime;

/// <summary>Opt-in, allocation-free per-frame CPU timing for presentation stages.</summary>
internal sealed class RenderPerf
{
    private const int Capacity = 600;
    private static readonly string[] Names = { "input/pick", "map", "labels", "orders", "units", "fleets", "air", "hover", "ui", "EndDrawing/flush+swap" };
    private readonly double[][] _samples = Enumerable.Range(0, Names.Length).Select(_ => new double[Capacity]).ToArray();
    private readonly double[] _frameMs = new double[Capacity];
    private readonly double[] _allocKb = new double[Capacity];
    private readonly double[] _gcPauseMs = new double[Capacity];
    private readonly int[] _gc0 = new int[Capacity], _gc1 = new int[Capacity], _gc2 = new int[Capacity];
    private int _count, _next;
    private long _stageStart, _allocated;
    private TimeSpan _pauseStart;
    private int _stage;

    public void Begin()
    {
        _stageStart = Stopwatch.GetTimestamp();
        _allocated = GC.GetAllocatedBytesForCurrentThread();
        _pauseStart = GC.GetTotalPauseDuration();
        _stage = 0;
    }

    public void Mark(int nextStage)
    {
        long now = Stopwatch.GetTimestamp();
        _samples[_stage][_next] = (now - _stageStart) * 1000.0 / Stopwatch.Frequency;
        _stage = nextStage;
        _stageStart = now;
    }

    public void End(double raylibFrameMs)
    {
        long now = Stopwatch.GetTimestamp();
        _samples[_stage][_next] = (now - _stageStart) * 1000.0 / Stopwatch.Frequency;
        _frameMs[_next] = raylibFrameMs;
        _allocKb[_next] = (GC.GetAllocatedBytesForCurrentThread() - _allocated) / 1024.0;
        _gcPauseMs[_next] = (GC.GetTotalPauseDuration() - _pauseStart).TotalMilliseconds;
        _gc0[_next] = GC.CollectionCount(0);
        _gc1[_next] = GC.CollectionCount(1);
        _gc2[_next] = GC.CollectionCount(2);
        _next = (_next + 1) % Capacity;
        if (_count < Capacity) _count++;
    }

    public string Report(double windowSeconds, double simMs, double simFrames)
    {
        if (_count == 0) return string.Empty;
        string P(double[] values, string suffix = "ms")
        {
            var ordered = new double[_count];
            Array.Copy(values, ordered, _count);
            Array.Sort(ordered);
            double At(double q) => ordered[Math.Min(_count - 1, (int)Math.Ceiling(q * _count) - 1)];
            return $"p50/p95/p99 {At(.50):0.0}/{At(.95):0.0}/{At(.99):0.0}{suffix}";
        }
        int last = (_next - 1 + Capacity) % Capacity;
        int gc0 = _gc0[last] - _gc0[0], gc1 = _gc1[last] - _gc1[0], gc2 = _gc2[last] - _gc2[0];
        var parts = new List<string>(Names.Length + 2)
        {
            $"frame {P(_frameMs)} n={_count}", $"avg FPS {_count / windowSeconds:0.0}", $"alloc {Enumerable.Range(0, _count).Average(i => _allocKb[i]):0.0} KB/frame", $"GC Δ {gc0}/{gc1}/{gc2}, pause {Enumerable.Range(0, _count).Sum(i => _gcPauseMs[i]):0.0} ms"
        };
        for (int s = 0; s < Names.Length; s++) parts.Add($"{Names[s]} {P(_samples[s])}");
        parts.Add($"simulation {simMs / Math.Max(1, simFrames):0.0} ms/frame");
        return string.Join("; ", parts);
    }

    public void Clear() { _count = 0; _next = 0; }
}
