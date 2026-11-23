using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace AudioNoiseDiagnostics {
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDeviceCollection {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IDevice device);
    }
    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICaptureClient {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IRenderClient {
        [PreserveSig] int GetBuffer(uint frames, out IntPtr data);
        [PreserveSig] int ReleaseBuffer(uint frames, uint flags);
    }
    public class RenderEndpoint { public string Id; public string Name; public override string ToString() { return Name; } }
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit,Size=24)] struct PropertyValue { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }
    [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index,out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key,out PropertyValue value);
        [PreserveSig] int SetValue(ref PropertyKey key,ref PropertyValue value);
        [PreserveSig] int Commit();
    }
    public class WaveFormat {
        public byte[] Bytes; public int Rate, Channels, Bits, Align; public bool Float;
        public static WaveFormat Parse(byte[] bytes) {
            if (bytes.Length < 16) throw new InvalidDataException("WAV format is truncated.");
            var f=new WaveFormat { Bytes=bytes, Channels=BitConverter.ToUInt16(bytes,2), Rate=BitConverter.ToInt32(bytes,4), Align=BitConverter.ToUInt16(bytes,12), Bits=BitConverter.ToUInt16(bytes,14) };
            int tag=BitConverter.ToUInt16(bytes,0);
            if (tag==65534) { if (bytes.Length<40) throw new InvalidDataException("Extensible format is truncated."); tag=BitConverter.ToUInt16(bytes,24); }
            f.Float=tag==3;
            if ((tag!=1 && tag!=3) || f.Channels<1 || f.Channels>32 || f.Rate<8000 || f.Rate>384000 || f.Align!=f.Channels*(f.Bits/8) ||
                (f.Float ? (f.Bits!=32 && f.Bits!=64) : (f.Bits!=16 && f.Bits!=24 && f.Bits!=32))) throw new NotSupportedException("Unsupported PCM/float audio format.");
            return f;
        }
        internal static WaveFormat FromPointer(IntPtr p) {
            int length=18+(ushort)Marshal.ReadInt16(p,16);
            if (length>256) throw new InvalidDataException("Invalid mix format.");
            var bytes=new byte[length]; Marshal.Copy(p,bytes,0,length); return Parse(bytes);
        }
    }
    public class WaveData {
        public WaveFormat Format; public byte[] Data;
        public int Frames { get { return Data.Length/Format.Align; } }
        public double Sample(int frame,int channel) {
            if (frame<0 || frame>=Frames) return 0;
            int offset=frame*Format.Align+Math.Min(channel,Format.Channels-1)*(Format.Bits/8);
            if (Format.Float) return Format.Bits==32 ? BitConverter.ToSingle(Data,offset) : BitConverter.ToDouble(Data,offset);
            if (Format.Bits==16) return BitConverter.ToInt16(Data,offset)/32768.0;
            if (Format.Bits==24) { int n=Data[offset]|(Data[offset+1]<<8)|(Data[offset+2]<<16); if ((n&0x800000)!=0) n|=unchecked((int)0xff000000); return n/8388608.0; }
            return BitConverter.ToInt32(Data,offset)/2147483648.0;
        }
        public static WaveData Load(string path) {
            using (var r=new BinaryReader(File.OpenRead(path))) {
                if (Encoding.ASCII.GetString(r.ReadBytes(4))!="RIFF") throw new InvalidDataException("Not a RIFF WAV.");
                r.ReadUInt32(); if (Encoding.ASCII.GetString(r.ReadBytes(4))!="WAVE") throw new InvalidDataException("Not a WAV.");
                WaveFormat format=null; byte[] data=null;
                while (r.BaseStream.Position+8<=r.BaseStream.Length) {
                    string id=Encoding.ASCII.GetString(r.ReadBytes(4)); uint size=r.ReadUInt32();
                    if (size>268435456 || size>r.BaseStream.Length-r.BaseStream.Position) throw new InvalidDataException("Invalid or oversized WAV chunk.");
                    if (id=="fmt ") format=WaveFormat.Parse(r.ReadBytes((int)size));
                    else if (id=="data") data=r.ReadBytes((int)size);
                    else r.BaseStream.Seek(size,SeekOrigin.Current);
                    if ((size&1)!=0 && r.BaseStream.Position<r.BaseStream.Length) r.BaseStream.Position++;
                }
                if (format==null || data==null || data.Length%format.Align!=0) throw new InvalidDataException("Incomplete WAV.");
                return new WaveData { Format=format, Data=data };
            }
        }
    }
    public sealed class WaveSink : IDisposable {
        readonly BinaryWriter writer; readonly WaveFormat format; readonly long sizePosition, factPosition;
        public long Frames { get; private set; }
        public WaveSink(string path,WaveFormat format) {
            this.format=format; writer=new BinaryWriter(new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read));
            writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(0u); writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write((uint)format.Bytes.Length); writer.Write(format.Bytes); if ((format.Bytes.Length&1)!=0) writer.Write((byte)0);
            writer.Write(Encoding.ASCII.GetBytes("fact")); writer.Write(4u); factPosition=writer.BaseStream.Position; writer.Write(0u);
            writer.Write(Encoding.ASCII.GetBytes("data")); sizePosition=writer.BaseStream.Position; writer.Write(0u); writer.Flush();
        }
        public void Write(byte[] data,int count) { writer.Write(data,0,count); Frames+=count/format.Align; }
        public void Silence(long frames) {
            var zeros=new byte[format.Align*4096];
            while (frames>0) { int n=(int)Math.Min(frames,4096); Write(zeros,n*format.Align); frames-=n; }
        }
        public void Dispose() {
            long end=writer.BaseStream.Position;
            writer.BaseStream.Position=4; writer.Write((uint)(end-8)); writer.BaseStream.Position=sizePosition; writer.Write((uint)(Frames*format.Align));
            writer.BaseStream.Position=factPosition; writer.Write((uint)Frames); writer.Flush(); writer.Dispose();
        }
    }
    internal static class NativeAudio {
        internal static IDevice Device(string id,out object enumerator) {
            enumerator=new Enumerator(); IDevice device;
            Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumerator).GetDevice(id,out device)); return device;
        }
        internal static IAudioClient Client(IDevice device) {
            object result; Guid iid=typeof(IAudioClient).GUID;
            Marshal.ThrowExceptionForHR(device.Activate(ref iid,23,IntPtr.Zero,out result)); return (IAudioClient)result;
        }
        internal static void Release(object value) { if (value!=null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
    }
    internal sealed class WaveRenderer : IDisposable {
        [StructLayout(LayoutKind.Explicit)] struct FloatBits { [FieldOffset(0)] public float Single; [FieldOffset(0)] public double Double; [FieldOffset(0)] public long Bits; }
        object enumerator; IDevice device; IAudioClient client; IRenderClient render; IntPtr formatPointer;
        WaveFormat mix; WaveData source; double position; bool loop; uint bufferSize;
        internal bool Exhausted; internal long SubmittedFrames; internal int OutputRate;
        internal WaveRenderer(string endpointId,string file,bool loop) {
            try {
                this.loop=loop; source=WaveData.Load(file); device=NativeAudio.Device(endpointId,out enumerator); client=NativeAudio.Client(device);
                Marshal.ThrowExceptionForHR(client.GetMixFormat(out formatPointer)); mix=WaveFormat.FromPointer(formatPointer); OutputRate=mix.Rate;
                Guid session=Guid.Empty; Marshal.ThrowExceptionForHR(client.Initialize(0,0,1000000,0,formatPointer,ref session));
                object service; Guid iid=typeof(IRenderClient).GUID; Marshal.ThrowExceptionForHR(client.GetService(ref iid,out service)); render=(IRenderClient)service;
                Marshal.ThrowExceptionForHR(client.GetBufferSize(out bufferSize)); Pump(); Marshal.ThrowExceptionForHR(client.Start());
            } catch { Dispose(); throw; }
        }
        internal bool Pump() {
            uint padding; Marshal.ThrowExceptionForHR(client.GetCurrentPadding(out padding));
            if (Exhausted) return padding>0;
            uint available=bufferSize-padding; if (available==0) return true;
            if (!loop) available=(uint)Math.Min(available,Math.Ceiling((source.Frames-position)*mix.Rate/source.Format.Rate));
            if (available==0) { Exhausted=true; return padding>0; }
            var bytes=new byte[available*mix.Align];
            for (int frame=0;frame<available;frame++) {
                if (position>=source.Frames) position=loop ? position%source.Frames : source.Frames;
                int lower=(int)position; double fraction=position-lower; int upper=lower+1;
                if (loop) upper%=source.Frames;
                for (int channel=0;channel<mix.Channels;channel++) {
                    double a=0,b=0;
                    if (mix.Channels==1 && source.Format.Channels>1) { for(int c=0;c<source.Format.Channels;c++) { a+=source.Sample(lower,c)/source.Format.Channels;b+=source.Sample(upper,c)/source.Format.Channels; } }
                    else { a=source.Sample(lower,channel);b=source.Sample(upper,channel); }
                    double value=a+(b-a)*fraction;
                    if (Double.IsNaN(value)||Double.IsInfinity(value)) value=0;
                    int offset=frame*mix.Align+channel*(mix.Bits/8);
                    if (mix.Float) { var bits=new FloatBits();if(mix.Bits==32)bits.Single=(float)value;else bits.Double=value;for(int j=0;j<mix.Bits/8;j++)bytes[offset+j]=(byte)(bits.Bits>>(8*j)); }
                    else {
                        value=Math.Max(-1,Math.Min(0.999999999,value)); long n=(long)(value*(mix.Bits==16?32768.0:mix.Bits==24?8388608.0:2147483648.0));
                        for(int j=0;j<mix.Bits/8;j++) bytes[offset+j]=(byte)(n>>(8*j));
                    }
                }
                position+=(double)source.Format.Rate/mix.Rate;
            }
            IntPtr data; Marshal.ThrowExceptionForHR(render.GetBuffer(available,out data));
            try { Marshal.Copy(bytes,0,data,bytes.Length); } finally { Marshal.ThrowExceptionForHR(render.ReleaseBuffer(available,0)); }
            SubmittedFrames+=available;
            if (!loop && position>=source.Frames) Exhausted=true;
            return true;
        }
        public void Dispose() {
            if (client!=null) { try { client.Stop(); } catch { } }
            NativeAudio.Release(render); NativeAudio.Release(client); NativeAudio.Release(device); NativeAudio.Release(enumerator);
            render=null; client=null; device=null; enumerator=null;
            if (formatPointer!=IntPtr.Zero) { Marshal.FreeCoTaskMem(formatPointer); formatPointer=IntPtr.Zero; }
        }
    }
    public class PacketFlag { public double OffsetSeconds; public uint Flags; public ulong DeviceFramePosition; }
    public sealed class AudioProbe : IDisposable {
        readonly string endpointId,path,reference,renderEndpointId; readonly bool loopback; readonly int maxSeconds; readonly Thread thread;
        volatile bool stop; public volatile bool Finished; public volatile string Status="Starting";
        public string ErrorCode; public string StartedUtc,EndedUtc; public int SampleRate,Channels,Bits;
        public long CapturedFrames,WrittenFrames,InsertedSilenceFrames,PacketCount,Discontinuities,TimestampErrors;
        public long StartedQpc,EndedQpc; public long QpcFrequency=Stopwatch.Frequency;
        public double ElapsedSeconds,ReferenceStartOffsetSeconds; public bool SizeLimitReached;
        readonly List<PacketFlag> flags=new List<PacketFlag>();
        public PacketFlag[] FlagEvents { get { lock(flags) { return flags.ToArray(); } } }
        public static AudioProbe Start(string endpointId,string path,string reference,int maxSeconds) { return new AudioProbe(endpointId,endpointId,path,reference,maxSeconds,true); }
        public static AudioProbe StartMicrophone(string inputId,string outputId,string path,string reference,int maxSeconds) { return new AudioProbe(inputId,outputId,path,reference,maxSeconds,false); }
        AudioProbe(string endpointId,string renderEndpointId,string path,string reference,int maxSeconds,bool loopback) {
            if (maxSeconds<1||maxSeconds>300) throw new ArgumentOutOfRangeException("maxSeconds");
            this.endpointId=endpointId;this.renderEndpointId=renderEndpointId;this.path=path;this.reference=reference;this.maxSeconds=maxSeconds;this.loopback=loopback;
            thread=new Thread(Run);thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
        }
        public void Stop() { stop=true; }
        public void Dispose() { Stop(); if (!thread.Join(5000)) throw new TimeoutException("Audio recording did not stop."); }
        void Run() {
            object enumerator=null; IDevice device=null; IAudioClient client=null; ICaptureClient capture=null; IntPtr pointer=IntPtr.Zero; WaveSink sink=null; WaveRenderer renderer=null;
            var clock=new Stopwatch();
            try {
                device=NativeAudio.Device(endpointId,out enumerator); client=NativeAudio.Client(device);
                Marshal.ThrowExceptionForHR(client.GetMixFormat(out pointer)); var mix=WaveFormat.FromPointer(pointer);
                SampleRate=mix.Rate;Channels=mix.Channels;Bits=mix.Bits;
                Guid session=Guid.Empty; Marshal.ThrowExceptionForHR(client.Initialize(0,loopback?0x20000u:0u,1000000,0,pointer,ref session));
                object service;Guid iid=typeof(ICaptureClient).GUID;Marshal.ThrowExceptionForHR(client.GetService(ref iid,out service));capture=(ICaptureClient)service;
                sink=new WaveSink(path,mix); Marshal.ThrowExceptionForHR(client.Start());
                StartedQpc=Stopwatch.GetTimestamp();double startQpc=(double)StartedQpc/Stopwatch.Frequency;
                StartedUtc=DateTime.UtcNow.ToString("o");clock.Start();Status="Recording";
                if (!String.IsNullOrEmpty(reference)) { ReferenceStartOffsetSeconds=clock.Elapsed.TotalSeconds; renderer=new WaveRenderer(renderEndpointId,reference,true); }
                long maximumFrames=268435456/mix.Align;
                while (!stop && clock.Elapsed.TotalSeconds<maxSeconds && sink.Frames<maximumFrames) {
                    uint packet;Marshal.ThrowExceptionForHR(capture.GetNextPacketSize(out packet));
                    while (packet>0 && !stop && clock.Elapsed.TotalSeconds<maxSeconds && sink.Frames<maximumFrames) {
                        IntPtr data; uint frames,packetFlags;ulong devicePosition,qpc;
                        Marshal.ThrowExceptionForHR(capture.GetBuffer(out data,out frames,out packetFlags,out devicePosition,out qpc));
                        try {
                            if (frames==0) break;
                            if ((packetFlags&1)!=0) Discontinuities++;
                            if ((packetFlags&4)!=0) TimestampErrors++;
                            if ((packetFlags&5)!=0) { lock(flags) { if(flags.Count<1000) flags.Add(new PacketFlag { OffsetSeconds=clock.Elapsed.TotalSeconds,Flags=packetFlags,DeviceFramePosition=devicePosition }); } }
                            if ((packetFlags&4)==0) {
                                long target=(long)Math.Round((qpc/10000000.0-startQpc)*mix.Rate);
                                long gap=Math.Min(target-sink.Frames,maximumFrames-sink.Frames);
                                // Preserve idle intervals; small timestamp jitter is not treated as a gap.
                                if (gap>mix.Rate/100) { sink.Silence(gap);InsertedSilenceFrames+=gap; }
                            }
                            int count=(int)Math.Min(frames,maximumFrames-sink.Frames);
                            var bytes=new byte[count*mix.Align];
                            if ((packetFlags&2)==0 && bytes.Length>0) Marshal.Copy(data,bytes,0,bytes.Length);
                            sink.Write(bytes,bytes.Length);CapturedFrames+=count;PacketCount++;
                        } finally { if(frames>0) Marshal.ThrowExceptionForHR(capture.ReleaseBuffer(frames)); }
                        Marshal.ThrowExceptionForHR(capture.GetNextPacketSize(out packet));
                    }
                    if (renderer!=null) renderer.Pump();
                    WrittenFrames=sink.Frames;ElapsedSeconds=clock.Elapsed.TotalSeconds;Thread.Sleep(3);
                }
                long tail=Math.Min((long)(clock.Elapsed.TotalSeconds*mix.Rate),maximumFrames)-sink.Frames;
                if (tail>0) { sink.Silence(tail);InsertedSilenceFrames+=tail; }
                WrittenFrames=sink.Frames;SizeLimitReached=sink.Frames>=maximumFrames;
                Status=CapturedFrames==0 ? "NoAudioData" : "Completed";
            } catch(Exception e) { ErrorCode="0x"+e.HResult.ToString("X8");Status="Failed"; }
            finally {
                if(renderer!=null) renderer.Dispose();if(client!=null) { try {client.Stop();} catch {} }
                if(sink!=null) { try {sink.Dispose();} catch(Exception e) { ErrorCode="0x"+e.HResult.ToString("X8");Status="Failed"; } }
                if(pointer!=IntPtr.Zero) Marshal.FreeCoTaskMem(pointer);
                NativeAudio.Release(capture);NativeAudio.Release(client);NativeAudio.Release(device);NativeAudio.Release(enumerator);
                clock.Stop();ElapsedSeconds=clock.Elapsed.TotalSeconds;EndedUtc=DateTime.UtcNow.ToString("o");EndedQpc=Stopwatch.GetTimestamp();Finished=true;
            }
        }
    }
    public sealed class AudioPlayback : IDisposable {
        readonly Thread thread;volatile bool stop;public volatile bool Finished;public volatile string Status="Starting";public string ErrorCode;
        public double PlayedSeconds;public bool Completed;
        public static AudioPlayback Start(string endpointId,string path) { return new AudioPlayback(endpointId,path); }
        AudioPlayback(string endpointId,string path) { thread=new Thread(()=>Run(endpointId,path));thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start(); }
        void Run(string id,string path) {
            WaveRenderer renderer=null;var clock=Stopwatch.StartNew();
            try { renderer=new WaveRenderer(id,path,false);Status="Playing";while(!stop && renderer.Pump()) { PlayedSeconds=clock.Elapsed.TotalSeconds;Thread.Sleep(5); } Completed=!stop;Status=Completed?"Completed":"Stopped"; }
            catch(Exception e) { ErrorCode="0x"+e.HResult.ToString("X8");Status="Failed"; }
            finally { if(renderer!=null)renderer.Dispose();PlayedSeconds=clock.Elapsed.TotalSeconds;Finished=true; }
        }
        public void Stop() { stop=true; }
        public void Dispose() {Stop();if(!thread.Join(5000))throw new TimeoutException("Playback did not stop.");}
    }
    public static class AudioFiles {
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropertyValue value);
        static string DeviceName(IDevice device,string fallback) {
            IntPtr raw=IntPtr.Zero;IPropertyStore store=null;
            try {
                Marshal.ThrowExceptionForHR(device.OpenPropertyStore(0,out raw));
                store=(IPropertyStore)Marshal.GetObjectForIUnknown(raw);Marshal.Release(raw);raw=IntPtr.Zero;
                var key=new PropertyKey { Format=new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),Id=14 };
                PropertyValue value;Marshal.ThrowExceptionForHR(store.GetValue(ref key,out value));
                try { if(value.Type==31 && value.Pointer!=IntPtr.Zero)return Marshal.PtrToStringUni(value.Pointer); }
                finally {PropVariantClear(ref value);}
            } catch { }
            finally {if(raw!=IntPtr.Zero)Marshal.Release(raw);NativeAudio.Release(store);}
            return fallback;
        }
        public static RenderEndpoint[] Endpoints() { return EnumerateEndpoints(0); }
        public static RenderEndpoint[] InputEndpoints() { return EnumerateEndpoints(1); }
        static RenderEndpoint[] EnumerateEndpoints(int flow) {
            object enumerator=null;IDeviceCollection collection=null;IntPtr raw=IntPtr.Zero;
            var result=new List<RenderEndpoint>();
            try {
                enumerator=new Enumerator();Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumerator).EnumAudioEndpoints(flow,1,out raw));
                collection=(IDeviceCollection)Marshal.GetObjectForIUnknown(raw);Marshal.Release(raw);raw=IntPtr.Zero;
                uint count;Marshal.ThrowExceptionForHR(collection.GetCount(out count));
                for(uint i=0;i<count;i++) {
                    IDevice device=null;
                    try {
                        Marshal.ThrowExceptionForHR(collection.Item(i,out device));string id;Marshal.ThrowExceptionForHR(device.GetId(out id));
                        string name=DeviceName(device,"Audio output "+(i+1));
                        result.Add(new RenderEndpoint {Id=id,Name=name});
                    } finally {NativeAudio.Release(device);}
                }
                return result.ToArray();
            } finally { if(raw!=IntPtr.Zero)Marshal.Release(raw);NativeAudio.Release(collection);NativeAudio.Release(enumerator); }
        }
        public static void GenerateReference(string path) { GenerateReference(path,10,false); }
        public static void GenerateFollowUpReference(string path,int seconds) {
            if(seconds<10||seconds>300||seconds%10!=0)throw new ArgumentOutOfRangeException("seconds");
            GenerateReference(path,seconds,true);
        }
        static void GenerateReference(string path,int seconds,bool indexed) {
            var format=new byte[16];Buffer.BlockCopy(BitConverter.GetBytes((ushort)1),0,format,0,2);Buffer.BlockCopy(BitConverter.GetBytes((ushort)2),0,format,2,2);
            Buffer.BlockCopy(BitConverter.GetBytes(48000),0,format,4,4);Buffer.BlockCopy(BitConverter.GetBytes(192000),0,format,8,4);Buffer.BlockCopy(BitConverter.GetBytes((ushort)4),0,format,12,2);Buffer.BlockCopy(BitConverter.GetBytes((ushort)16),0,format,14,2);
            using(var sink=new WaveSink(path,WaveFormat.Parse(format))) {
                var data=new byte[48000*seconds*4];
                for(int i=0;i<48000*seconds;i++) {
                    double t=(i%480000)/48000.0;double a=0,b=0;double local=0,length=0;
                    if(t>=1&&t<3) {local=t-1;length=2;a=b=Math.Sin(2*Math.PI*440*local);}
                    else if(t>=3&&t<5) {local=t-3;length=2;a=Math.Sin(2*Math.PI*1000*local);b=Math.Sin(2*Math.PI*660*local);}
                    else if(t>=5&&t<8) {local=t-5;length=3;a=b=(Math.Sin(2*Math.PI*220*local)+Math.Sin(2*Math.PI*440*local)+Math.Sin(2*Math.PI*880*local))/3;}
                    else if(t>=8&&t<9) {local=t-8;length=1;a=b=Math.Sin(2*Math.PI*(200*local+1900*local*local));}
                    double envelope=length==0?0:Math.Min(1,Math.Min(local/0.01,(length-local)/0.01));
                    if(indexed&&t<1) {
                        int bit=(int)((t-0.08)/0.12);double pulse=t-0.08-bit*0.12;
                        if(t>=0.08&&bit>=0&&bit<6&&pulse>=0&&pulse<0.06) {
                            int index=i/480000+1;double hz=(index&(1<<bit))!=0?1400:700;
                            a=b=Math.Sin(2*Math.PI*hz*pulse);envelope=Math.Min(1,Math.Min(pulse/0.005,(0.06-pulse)/0.005));
                        }else{a=b=0;envelope=0;}
                    }
                    short left=(short)(a*envelope*0.08*32767),right=(short)(b*envelope*0.08*32767);
                    data[i*4]=(byte)left;data[i*4+1]=(byte)(left>>8);data[i*4+2]=(byte)right;data[i*4+3]=(byte)(right>>8);
                }
                sink.Write(data,data.Length);
            }
        }
    }
}
