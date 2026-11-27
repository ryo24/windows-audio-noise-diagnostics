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
        [PreserveSig] int GetDevicePeriod(out long normal, out long minimum);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object result);
    }
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint channels);
        [PreserveSig] int SetMasterVolumeLevel(float value,ref Guid context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float value,ref Guid context);
        [PreserveSig] int GetMasterVolumeLevel(out float value);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float value);
        [PreserveSig] int SetChannelVolumeLevel(uint channel,float value,ref Guid context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel,float value,ref Guid context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel,out float value);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel,out float value);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute,ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }
    public class EndpointInfo {
        public string Id;
        public int SampleRate;
        public int Channels;
        public int ContainerBits;
        public long? DefaultPeriod100ns;
        public long? MinimumPeriod100ns;
        public string PeriodError;
        public float? VolumeScalar;
        public bool? Muted;
        public string VolumeError;
        public string FormatNote = "Windows共有モードのミックス形式。DACの物理ビット深度や音声拡張の状態を示す値ではありません。";
    }
    public static class Endpoint {
        public static EndpointInfo Read() { return Read(null); }
        public static EndpointInfo Read(string endpointId) {
            object enumerator = null, audio = null, volume = null;
            IDevice device = null;
            IntPtr format = IntPtr.Zero;
            try {
                enumerator = new Enumerator();
                if(String.IsNullOrEmpty(endpointId)) Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumerator).GetDefaultAudioEndpoint(0, 1, out device));
                else Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumerator).GetDevice(endpointId, out device));
                var result = new EndpointInfo();
                Marshal.ThrowExceptionForHR(device.GetId(out result.Id));
                Guid iid = typeof(IAudioClient).GUID;
                Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23, IntPtr.Zero, out audio));
                Marshal.ThrowExceptionForHR(((IAudioClient)audio).GetMixFormat(out format));
                result.Channels = (ushort)Marshal.ReadInt16(format, 2);
                result.SampleRate = Marshal.ReadInt32(format, 4);
                result.ContainerBits = (ushort)Marshal.ReadInt16(format, 14);
                long normal, minimum;
                int periodResult = ((IAudioClient)audio).GetDevicePeriod(out normal, out minimum);
                if (periodResult >= 0) { result.DefaultPeriod100ns=normal; result.MinimumPeriod100ns=minimum; }
                else { result.PeriodError="0x"+periodResult.ToString("X8"); }
                Guid volumeId=typeof(IEndpointVolume).GUID;
                int volumeResult=device.Activate(ref volumeId,23,IntPtr.Zero,out volume);
                if(volumeResult>=0) {
                    float scalar;bool muted;
                    int levelResult=((IEndpointVolume)volume).GetMasterVolumeLevelScalar(out scalar);
                    int muteResult=((IEndpointVolume)volume).GetMute(out muted);
                    if(levelResult>=0)result.VolumeScalar=scalar;else result.VolumeError="0x"+levelResult.ToString("X8");
                    if(muteResult>=0)result.Muted=muted;else result.VolumeError="0x"+muteResult.ToString("X8");
                } else result.VolumeError="0x"+volumeResult.ToString("X8");
                return result;
            } finally {
                if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format);
                if (audio != null) Marshal.ReleaseComObject(audio);
                if (volume != null) Marshal.ReleaseComObject(volume);
                if (device != null) Marshal.ReleaseComObject(device);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }
    }
}
