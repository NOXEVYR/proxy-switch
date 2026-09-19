param([string]$Destination=(Join-Path $PSScriptRoot 'assets'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
# Original vector geometry, rendered independently at each Windows icon size.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging; using System.IO;
public static class FlowBrand {
 public static Bitmap Render(int size) {
  var b=new Bitmap(size,size,PixelFormat.Format32bppArgb);
  using(var g=Graphics.FromImage(b)) {
   g.SmoothingMode=SmoothingMode.AntiAlias; g.ScaleTransform(size/1024f,size/1024f);
   var p=new GraphicsPath(); int d=360;
   p.AddArc(52,52,d,d,180,90);p.AddArc(612,52,d,d,270,90);p.AddArc(612,612,d,d,0,90);p.AddArc(52,612,d,d,90,90);p.CloseFigure();
   using(p)using(var fill=new LinearGradientBrush(new Point(52,52),new Point(972,972),Color.FromArgb(30,52,57),Color.FromArgb(12,24,30)))g.FillPath(fill,p);
   using(var route=new GraphicsPath())using(var pen=new Pen(Color.FromArgb(90,224,184),72)) {
    pen.StartCap=pen.EndCap=LineCap.Round;pen.LineJoin=LineJoin.Round;
    route.AddLine(260,512,400,512);route.AddBezier(400,512,524,512,508,692,630,692);route.AddLine(630,692,744,692);g.DrawPath(pen,route);
    g.DrawLines(pen,new[]{new Point(670,618),new Point(744,692),new Point(670,766)});
   }
   using(var route=new GraphicsPath())using(var pen=new Pen(Color.FromArgb(232,249,244),72)) {
    pen.StartCap=pen.EndCap=LineCap.Round;pen.LineJoin=LineJoin.Round;
    route.AddLine(260,512,400,512);route.AddBezier(400,512,524,512,508,332,630,332);route.AddLine(630,332,744,332);g.DrawPath(pen,route);
    g.DrawLines(pen,new[]{new Point(670,258),new Point(744,332),new Point(670,406)});
   }
  } return b;
 }
 public static void Build(string folder) {
  Directory.CreateDirectory(folder);
  using(var b=Render(1024))b.Save(Path.Combine(folder,"FlowSwitch.png"),ImageFormat.Png);
  int[] sizes={16,24,32,48,64,128,256}; var images=new byte[sizes.Length][];
  for(int i=0;i<sizes.Length;i++)using(var b=Render(sizes[i]))using(var s=new MemoryStream()){
   if(sizes[i]==256){b.Save(s,ImageFormat.Png);images[i]=s.ToArray();}
   else { b.Save(s,ImageFormat.Bmp);var bmp=s.ToArray();int mask=((sizes[i]+31)/32)*4*sizes[i];images[i]=new byte[bmp.Length-14+mask];Array.Copy(bmp,14,images[i],0,bmp.Length-14);Array.Copy(BitConverter.GetBytes(sizes[i]*2),0,images[i],8,4); }
  }
  using(var w=new BinaryWriter(File.Create(Path.Combine(folder,"FlowSwitch.ico")))) {
   w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)sizes.Length);int offset=6+16*sizes.Length;
   for(int i=0;i<sizes.Length;i++){w.Write((byte)(sizes[i]%256));w.Write((byte)(sizes[i]%256));w.Write((byte)0);w.Write((byte)0);w.Write((ushort)1);w.Write((ushort)32);w.Write(images[i].Length);w.Write(offset);offset+=images[i].Length;}
   foreach(var bytes in images)w.Write(bytes);
  }
 }
}
'@
[FlowBrand]::Build([IO.Path]::GetFullPath($Destination))
