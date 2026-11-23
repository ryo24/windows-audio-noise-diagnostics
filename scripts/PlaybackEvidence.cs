using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace AudioNoiseDiagnostics {
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr guid,uint flags,out IntPtr control);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr guid,uint flags,out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out ISessionEnumerator sessions);
    }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index,out ISessionControl2 control);
    }
    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(out IntPtr name);
        [PreserveSig] int SetDisplayName(IntPtr name,IntPtr context);
        [PreserveSig] int GetIconPath(out IntPtr path);
        [PreserveSig] int SetIconPath(IntPtr path,IntPtr context);
        [PreserveSig] int GetGroupingParam(out Guid grouping);
        [PreserveSig] int SetGroupingParam(ref Guid grouping,IntPtr context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference(bool optOut);
    }
    public class PlaybackSession {
        public string EndpointId, ProcessName, Status;
        public uint ProcessId; public bool MultipleProcesses;
    }
    public static class PlaybackEvidence {
        [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
        // Session enumeration runs in an MTA, independent of the Forms STA.
        public static PlaybackSession[] Read(string endpointId) {
            PlaybackSession[] result=null; Exception failure=null;
            var thread=new Thread(delegate(){try{result=ReadCore(endpointId);}catch(Exception error){failure=error;}});
            thread.IsBackground=true;thread.SetApartmentState(ApartmentState.MTA);thread.Start();
            if(!thread.Join(3000))throw new TimeoutException("Audio session query timed out.");
            if(failure!=null)throw new InvalidOperationException("Audio sessions unavailable.",failure);
            return result;
        }
        static PlaybackSession[] ReadCore(string endpointId) {
            object enumerator=null,manager=null;IDevice device=null;ISessionEnumerator sessions=null;
            var rows=new List<PlaybackSession>();
            try {
                enumerator=new Enumerator();Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumerator).GetDevice(endpointId,out device));
                var iid=typeof(ISessionManager2).GUID;Marshal.ThrowExceptionForHR(device.Activate(ref iid,23,IntPtr.Zero,out manager));
                Marshal.ThrowExceptionForHR(((ISessionManager2)manager).GetSessionEnumerator(out sessions));
                int count;Marshal.ThrowExceptionForHR(sessions.GetCount(out count));
                for(int i=0;i<Math.Min(count,256);i++) {
                    ISessionControl2 session=null;
                    try {
                        // GetSession returns IAudioSessionControl; QueryInterface for Control2.
                        Marshal.ThrowExceptionForHR(sessions.GetSession(i,out session));
                        int state;Marshal.ThrowExceptionForHR(session.GetState(out state));if(state!=1)continue;
                        uint pid;int hr=session.GetProcessId(out pid);Marshal.ThrowExceptionForHR(hr);
                        string name=pid==0?"SystemSounds":"Unavailable";
                        if(pid!=0){try{using(var process=Process.GetProcessById((int)pid)){name=process.ProcessName;}}catch{}}
                        rows.Add(new PlaybackSession{EndpointId=endpointId,ProcessId=pid,ProcessName=name,MultipleProcesses=hr==0x0889000d,Status="ActiveSessionNotProofOfAudibleSound"});
                    }finally{if(session!=null)Marshal.ReleaseComObject(session);}
                }
                return rows.ToArray();
            }finally {
                if(sessions!=null)Marshal.ReleaseComObject(sessions);if(manager!=null)Marshal.ReleaseComObject(manager);
                if(device!=null)Marshal.ReleaseComObject(device);if(enumerator!=null)Marshal.ReleaseComObject(enumerator);
            }
        }
    }
}
