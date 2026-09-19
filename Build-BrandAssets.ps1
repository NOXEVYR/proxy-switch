param([string]$Destination=(Join-Path $PSScriptRoot 'assets'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
# Package the approved PNG without redrawing its artwork. Keep alpha at every size.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging; using System.IO;
public static class FlowBrand {
 public static Bitmap Resize(Image source, int size) {
  var b=new Bitmap(size,size,PixelFormat.Format32bppArgb);
  using(var g=Graphics.FromImage(b)) {
   g.CompositingMode=CompositingMode.SourceCopy;
   g.InterpolationMode=InterpolationMode.HighQualityBicubic;
   g.PixelOffsetMode=PixelOffsetMode.HighQuality;
   using(var a=new ImageAttributes()) {
    a.SetWrapMode(WrapMode.TileFlipXY);
    g.DrawImage(source,new Rectangle(0,0,size,size),0,0,source.Width,source.Height,GraphicsUnit.Pixel,a);
   }
  } return b;
 }
 public static void Build(string source, string folder) {
  Directory.CreateDirectory(folder);
  string png=Path.Combine(folder,"FlowSwitch.png");
  if(!String.Equals(Path.GetFullPath(source),Path.GetFullPath(png),StringComparison.OrdinalIgnoreCase))File.Copy(source,png,true);
  int[] sizes={16,24,32,48,64,128,256}; var images=new byte[sizes.Length][];
  using(var original=Image.FromFile(source)) {
   if(original.Width!=original.Height)throw new InvalidDataException("Brand artwork must be square.");
   for(int i=0;i<sizes.Length;i++)using(var b=Resize(original,sizes[i]))using(var s=new MemoryStream()) {
    if(sizes[i]==256){b.Save(s,ImageFormat.Png);images[i]=s.ToArray();}
    else {
     b.Save(s,ImageFormat.Bmp);var bmp=s.ToArray();int mask=((sizes[i]+31)/32)*4*sizes[i];
     images[i]=new byte[bmp.Length-14+mask];Array.Copy(bmp,14,images[i],0,bmp.Length-14);
     Array.Copy(BitConverter.GetBytes(sizes[i]*2),0,images[i],8,4);
    }
   }
  }
  using(var w=new BinaryWriter(File.Create(Path.Combine(folder,"FlowSwitch.ico")))) {
   w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)sizes.Length);int offset=6+16*sizes.Length;
   for(int i=0;i<sizes.Length;i++){w.Write((byte)(sizes[i]%256));w.Write((byte)(sizes[i]%256));w.Write((byte)0);w.Write((byte)0);w.Write((ushort)1);w.Write((ushort)32);w.Write(images[i].Length);w.Write(offset);offset+=images[i].Length;}
   foreach(var bytes in images)w.Write(bytes);
  }
 }
}
'@
[FlowBrand]::Build((Join-Path $PSScriptRoot 'assets/FlowSwitch.png'),[IO.Path]::GetFullPath($Destination))
