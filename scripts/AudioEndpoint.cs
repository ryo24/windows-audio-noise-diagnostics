using System;
using System.Runtime.InteropServices;

namespace AudioNoiseDiagnostics {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class Enumerator { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint mask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDevice {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object result);
        [PreserveSig] int OpenPropertyStore(uint mode, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }
    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        [PreserveSig] int Initialize(int mode, uint flags, long duration, long period, IntPtr format, ref Guid session);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int mode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
    }
    public class EndpointInfo {
        public string Id;
        public int SampleRate;
        public int Channels;
        public int ContainerBits;
        public string FormatNote = "Windows共有モードのミックス形式。DACの物理ビット深度や音声拡張の状態を示す値ではありません。";
    }
    public static class Endpoint {
        public static EndpointInfo Read() {
            object enumerator = null, audio = null;
            IDevice device = null;
            IntPtr format = IntPtr.Zero;
            try {
                enumerator = new Enumerator();
                Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumerator).GetDefaultAudioEndpoint(0, 1, out device));
                var result = new EndpointInfo();
                Marshal.ThrowExceptionForHR(device.GetId(out result.Id));
                Guid iid = typeof(IAudioClient).GUID;
                Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23, IntPtr.Zero, out audio));
                Marshal.ThrowExceptionForHR(((IAudioClient)audio).GetMixFormat(out format));
                result.Channels = (ushort)Marshal.ReadInt16(format, 2);
                result.SampleRate = Marshal.ReadInt32(format, 4);
                result.ContainerBits = (ushort)Marshal.ReadInt16(format, 14);
                return result;
            } finally {
                if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format);
                if (audio != null) Marshal.ReleaseComObject(audio);
                if (device != null) Marshal.ReleaseComObject(device);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }
    }
}
