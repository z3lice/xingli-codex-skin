using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

// The live splash and the exported movie share this one renderer and clock.
// Geometry is flattened once; contours grow by arc length rather than a scan mask.
public sealed class XingliScene : FrameworkElement {
    public const double BootDuration = 7.2;
    private const double W = 1080, H = 608, SX = W / 1672.0, SY = H / 941.0;
    private readonly BitmapSource closed;
    private readonly BitmapSource pet;
    private readonly BitmapSource[] eyes;
    private readonly List<Trace> traces = new List<Trace>();
    private readonly List<Rain> drops = new List<Rain>();
    private readonly Geometry wordmark;
    private readonly XingliMotionSurface motion = new XingliMotionSurface();
    private int motionWidth = 1080, motionHeight = 608;
    private readonly Stopwatch clock = new Stopwatch();
    private readonly Typeface mono = new Typeface("Consolas");
    private readonly Typeface sans = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    private readonly Rect eyeRect = new Rect(1280 * SX, 310 * SY, 350 * SX, 215 * SY);
    private readonly LinearGradientBrush leftShade;
    private readonly LinearGradientBrush bottomShade;
    public double Time { get; set; }
    public string LaunchStatus { get; set; }
    public bool AppReady { get; set; }
    public bool Waiting { get; set; }
    public int FrameCount { get; private set; }
    public int LongFrameCount { get; private set; }
    public double RenderMilliseconds { get; private set; }
    private double lastFrame;
    private bool running;

    private sealed class Trace {
        public Point[] Points;
        public double[] Lengths;
        public double Total, Start, Duration, Width;
        public bool Mesh;
        public Pen Pen;
    }
    private sealed class Rain {
        public double X, Phase, Length;
        public int Cycles;
        public Pen Pen;
    }

    public XingliScene(string folder) {
        string closedPath = Path.Combine(folder, "xingli-closed.png");
        if (!File.Exists(closedPath)) closedPath = Path.Combine(folder, "xingli-closed.jpg");
        closed = Load(closedPath);
        string petPath = Path.Combine(folder,"xingli-portrait.png");
        if (File.Exists(petPath)) pet=Load(petPath);
        string atlasPath = Path.Combine(folder, "eye-atlas.png");
        if (File.Exists(atlasPath)) {
            BitmapSource atlas = Load(atlasPath);
            eyes = new BitmapSource[84];
            for (int i = 0; i < eyes.Length; i++) {
                eyes[i] = new CroppedBitmap(atlas, new Int32Rect((i % 12) * 350, (i / 12) * 215, 350, 215));
                eyes[i].Freeze();
            }
        } else { throw new FileNotFoundException("The continuous eyelid atlas is missing.", atlasPath); }
        LaunchStatus = "INITIALIZING INTERFACE";
        leftShade = new LinearGradientBrush();
        leftShade.StartPoint = new Point(0, .5); leftShade.EndPoint = new Point(1, .5);
        leftShade.GradientStops.Add(new GradientStop(Color.FromArgb(26, 0, 2, 5), 0));
        leftShade.GradientStops.Add(new GradientStop(Color.FromArgb(20, 0, 2, 5), .45));
        leftShade.GradientStops.Add(new GradientStop(Color.FromArgb(0, 0, 2, 5), .75));
        leftShade.Freeze();
        bottomShade = new LinearGradientBrush(Color.FromArgb(0, 0, 0, 0), Color.FromArgb(70, 0, 3, 7), 90); bottomShade.Freeze();
        FormattedText title = new FormattedText("ChatGPT", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Italic, FontWeights.SemiBold, FontStretches.Normal), 90, Brushes.White,1.0);
        wordmark = title.BuildGeometry(new Point(56, 231)); wordmark.Freeze();
        BuildContours();
        Random rng = new Random(10102026);
        for (int i = 0; i < 76; i++) {
            double x = rng.NextDouble() * W;
            byte alpha = (byte)(x > W * .72 ? rng.Next(12, 25) : rng.Next(18, 41));
            drops.Add(new Rain { X = x, Phase = rng.NextDouble(), Length = rng.Next(8, 23), Cycles = rng.Next(1, 4),
                Pen = MakePen(Color.FromArgb(alpha, 211, 232, 248), i % 9 == 0 ? .6 : .36) });
        }
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        Unloaded += delegate { Stop(); };
    }

    private static BitmapSource Load(string path) {
        BitmapImage b = new BitmapImage(); b.BeginInit(); b.CacheOption = BitmapCacheOption.OnLoad;
        b.UriSource = new Uri(path, UriKind.Absolute); b.EndInit(); b.Freeze(); return b;
    }
    private static Pen MakePen(Color color, double width) {
        SolidColorBrush brush = new SolidColorBrush(color); brush.Freeze();
        Pen p = new Pen(brush, width); p.StartLineCap = PenLineCap.Round; p.EndLineCap = PenLineCap.Round;
        p.LineJoin = PenLineJoin.Round; p.Freeze(); return p;
    }
    private static double Clamp(double v) { return Math.Max(0, Math.Min(1, v)); }
    private static double Smooth(double v) { v = Clamp(v); return v * v * (3 - 2 * v); }
    private static double Ease(double t, double start, double end) { return Smooth((t - start) / (end - start)); }
    private static SolidColorBrush Brush(byte a, byte r, byte g, byte b) {
        SolidColorBrush result = new SolidColorBrush(Color.FromArgb(a,r,g,b)); result.Freeze(); return result;
    }

    private void Add(string geometry, double start, double duration, bool mesh) {
        PathGeometry flat = Geometry.Parse(geometry).GetFlattenedPathGeometry(.18, ToleranceType.Absolute);
        foreach (PathFigure figure in flat.Figures) {
            List<Point> points = new List<Point>(); points.Add(figure.StartPoint);
            foreach (PathSegment segment in figure.Segments) {
                PolyLineSegment poly = segment as PolyLineSegment;
                LineSegment line = segment as LineSegment;
                if (poly != null) foreach (Point p in poly.Points) points.Add(p);
                if (line != null) points.Add(line.Point);
            }
            if (figure.IsClosed) points.Add(figure.StartPoint);
            double[] lengths = new double[points.Count];
            for (int i=1;i<points.Count;i++) lengths[i]=lengths[i-1]+(points[i]-points[i-1]).Length;
            traces.Add(new Trace { Points=points.ToArray(), Lengths=lengths, Total=lengths[lengths.Length-1], Start=start,
                Duration=duration, Width=mesh ? .28 : .45, Mesh=mesh,
                Pen=MakePen(mesh ? Color.FromRgb(202,224,244) : Color.FromRgb(244,250,255), mesh ? .28 : .45) });
        }
    }

    private void BuildContours() {
        // Major masses and silhouette only. No traced individual hair strands.
        Add("M 600,0 C 594,54 610,103 653,137 C 675,156 701,172 718,179", .20, .96, false);
        Add("M 670,0 C 673,47 684,71 722,89 C 746,100 751,125 736,151", .49, .86, false);
        Add("M 718,179 C 734,188 746,211 749,234", .74, .73, false);
        Add("M 590,34 C 568,53 568,83 591,107", .48, .78, false);
        Add("M 770,0 C 747,62 735,128 705,180 C 677,215 646,227 593,231", .32, 1.24, false);
        Add("M 689,231 C 645,272 603,297 570,333 C 544,356 518,369 480,377", .76, .96, false);
        Add("M 570,333 C 546,380 503,414 459,431 C 425,444 401,470 383,495", .93, 1.04, false);
        Add("M 752,288 C 733,363 681,424 617,473 C 573,508 530,531 473,552", 1.10, .92, false);
        Add("M 1057,0 C 1052,50 1058,115 1080,162", .62, .88, false);
        Add("M 880,10 C 859,73 839,123 829,183 C 817,236 827,295 852,329", .98, .92, false);
        Add("M 639,245 C 670,239 708,238 737,245 C 756,250 769,271 768,299 C 720,289 674,271 639,245", .38, .96, false);
        Add("M 721,257 C 731,272 747,285 764,286", 1.04, .63, false);
        Add("M 877,273 C 916,286 959,289 1021,276", .94, .89, false);
        Add("M 858,334 C 882,379 924,418 968,446 C 1001,466 1040,477 1080,474", .64, 1.26, false);
        Add("M 1080,348 C 1062,352 1050,363 1055,376 C 1061,382 1071,383 1080,381", 1.19, .79, false);
        Add("M 578,608 L 570,563 C 579,546 603,534 632,536 C 672,544 712,566 736,608", .88, 1.09, false);
        Add("M 970,505 C 1000,519 1026,526 1080,537", 1.31, .79, false);
        // Five additional lock boundaries outline the hairstyle's large masses.
        // They share the character mesh; these are not individual hair strands.
        Add("M 735,27 C 716,91 706,157 666,214 C 643,248 610,276 577,305", .41, 1.10, false);
        Add("M 821,0 C 790,84 786,168 812,241 C 831,295 848,348 849,404", .66, 1.25, false);
        Add("M 858,0 C 838,90 853,161 882,207 C 895,228 908,245 924,256", .84, .96, false);
        Add("M 987,4 C 966.2,60.6 961.5,102.3 973.3,138.9", .55, 1.02, false);
        Add("M 698,338 C 660,395 609,441 560,471", 1.04, 1.14, false);
        // Sparse curved sections communicate volume; no vertical sweeping scanner.
        Add("M 880,218 C 934,197 1009,203 1080,231", 1.48, .95, true);
        Add("M 865,318 C 923,306 1003,311 1080,337", 1.62, .85, true);
        Add("M 890,371 C 946,353 1015,358 1080,386", 1.79, .79, true);
        Add("M 931,418 C 977,401 1034,402 1080,421", 1.90, .77, true);
        Add("M 954,198 C 929,238 930,284 946,327 C 961,367 982,407 1001,459", 1.59, 1.14, true);
        Add("M 1031,213 C 1007,252 1008,296 1023,331 C 1037,365 1052,393 1067,425", 1.76, .93, true);
        Add("M 597,51 C 619,42 651,45 680,60", 1.54, .71, true);
        Add("M 622,105 C 649,88 686,92 724,110", 1.81, .70, true);
        Add("M 645,135 C 674,119 702,126 734,144", 1.95, .69, true);
        Add("M 574,566 C 615,564 671,580 718,601", 1.74, .96, true);
        Add("M 626,539 C 613,557 615,588 631,608", 1.88, .84, true);
    }

    public void Start() {
        if (running) return;
        running=true; clock.Restart(); lastFrame=0; FrameCount=0; LongFrameCount=0; RenderMilliseconds=0;
        CompositionTarget.Rendering += OnFrame;
    }
    public void Stop() { if (running) CompositionTarget.Rendering -= OnFrame; running=false; clock.Stop(); }
    private void OnFrame(object sender, EventArgs args) {
        Time=clock.Elapsed.TotalSeconds;
        if (lastFrame > 0 && Time-lastFrame > .034) LongFrameCount++;
        lastFrame=Time; FrameCount++; InvalidateVisual();
    }
    protected override void OnRender(DrawingContext dc) {
        base.OnRender(dc);
        Stopwatch drawWatch=Stopwatch.StartNew();
        dc.PushTransform(new ScaleTransform(ActualWidth/W,ActualHeight/H));
        DrawBoot(dc,Time); dc.Pop();
        RenderMilliseconds+=drawWatch.Elapsed.TotalMilliseconds;
    }

    public double Openness(double t) { return Ease(t,2.90,4.20); }
    private void DrawCharacter(DrawingContext dc, double openness) {
        dc.DrawImage(closed,new Rect(0,0,W,H));
        double sample=Clamp(openness)*(eyes.Length-1);
        int index=(int)Math.Floor(sample);
        dc.DrawImage(eyes[index],eyeRect);
        if (index+1 < eyes.Length) {
            dc.PushOpacity(sample-index); dc.DrawImage(eyes[index+1],eyeRect); dc.Pop();
        }
    }

    public void DrawBoot(DrawingContext dc, double t) {
        dc.DrawRectangle(Brush(255,0,1,3),null,new Rect(0,0,W,H));
        dc.DrawImage(motion.Render(CharacterTexture(t,Openness(t),true),t,motionWidth,motionHeight),new Rect(0,0,W,H));
        dc.DrawRectangle(leftShade,null,new Rect(0,0,W,H));
        dc.DrawRectangle(bottomShade,null,new Rect(0,0,W,H));
        dc.PushOpacity(.78*Ease(t,2.40,3.55)); DrawRain(dc,t); dc.Pop();
        DrawInterface(dc,t);
        if (pet!=null) {
            dc.PushOpacity(Ease(t,.04,.40));
            dc.DrawImage(pet,new Rect(996,491,78,117));
            dc.Pop();
        }
        dc.DrawRectangle(null,MakePen(Color.FromArgb(80,184,216,238),.65),new Rect(.5,.5,W-1,H-1));
    }

    private BitmapSource CharacterTexture(double t,double opening,bool boot) {
        DrawingVisual visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual,BitmapScalingMode.HighQuality);
        using (DrawingContext dc=visual.RenderOpen()) {
            dc.PushTransform(new ScaleTransform(motionWidth/W,motionHeight/H));
            if (boot) DrawBootCharacter(dc,t,opening);
            else DrawCharacter(dc,opening);
            dc.Pop();
        }
        RenderTargetBitmap image=new RenderTargetBitmap(motionWidth,motionHeight,96,96,PixelFormats.Pbgra32);
        image.Render(visual); image.Freeze(); return image;
    }

    private void DrawBootCharacter(DrawingContext dc,double t,double opening) {
        // Resolve the reveal onto the final black backdrop before projection;
        // this keeps very faint contours stable through WPF's 3D alpha passes.
        dc.DrawRectangle(Brush(255,0,1,3),null,new Rect(0,0,W,H));
        // Dim painted material is present as soon as the first contour begins.
        double material=.055*Ease(t,.18,1.40)+.945*Ease(t,1.25,2.85);
        dc.PushOpacity(material); DrawCharacter(dc,opening); dc.Pop();
        double meshFade=1-Ease(t,2.56,3.65);
        double contourFade=1-Ease(t,2.23,3.36);
        foreach (Trace trace in traces) {
            double progress=Ease(t,trace.Start,trace.Start+trace.Duration);
            if (progress <= 0) continue;
            double opacity=(trace.Mesh ? .49*meshFade : .82*contourFade)*Math.Min(1,progress*5);
            if (opacity<=.001) continue;
            dc.PushOpacity(opacity); dc.DrawGeometry(null,trace.Pen,Partial(trace,progress)); dc.Pop();
        }
        if (opening>0 && opening<1) DrawIrisCode(dc,t,opening);
    }

    private static Geometry Partial(Trace trace,double progress) {
        double target=trace.Total*progress;
        StreamGeometry g=new StreamGeometry();
        using (StreamGeometryContext c=g.Open()) {
            c.BeginFigure(trace.Points[0],false,false);
            for (int i=1;i<trace.Points.Length;i++) {
                if (trace.Lengths[i] <= target) c.LineTo(trace.Points[i],true,false);
                else {
                    double f=(target-trace.Lengths[i-1])/(trace.Lengths[i]-trace.Lengths[i-1]);
                    c.LineTo(trace.Points[i-1]+(trace.Points[i]-trace.Points[i-1])*Clamp(f),true,false); break;
                }
            }
        }
        g.Freeze(); return g;
    }

    private static Point Cubic(Point a,Point b,Point c,Point d,double t) {
        double u=1-t;
        return new Point(u*u*u*a.X+3*u*u*t*b.X+3*u*t*t*c.X+t*t*t*d.X,
            u*u*u*a.Y+3*u*u*t*b.Y+3*u*t*t*c.Y+t*t*t*d.Y);
    }
    private Geometry Aperture(double openness) {
        // Exact atlas aperture, including the closed lash extent. Text cannot
        // leak onto the moving skin/lash surface even at the first narrow slit.
        List<Point> upper=new List<Point>(),lower=new List<Point>();
        for (int i=0;i<=100;i++) {
            double f=i/100.0;
            Point closedP=Cubic(new Point(80,103),new Point(130,133),new Point(250,137),new Point(310,117),f);
            Point openU=Cubic(new Point(80,103),new Point(130,40),new Point(250,47),new Point(310,117),f);
            Point openL=Cubic(new Point(80,103),new Point(130,161),new Point(250,167),new Point(310,117),f);
            double lash=15*Smooth((closedP.X-78)/24)*Smooth((313-closedP.X)/22);
            double contact=closedP.Y+lash;
            double u=contact+(openU.Y+3-contact)*openness;
            double l=Math.Max(u,contact+(openL.Y-3-contact)*openness);
            // Inset a fraction of a source pixel from the antialiased lid edge.
            upper.Add(new Point((1280+closedP.X)*SX,(310+u+.65)*SY));
            lower.Add(new Point((1280+closedP.X)*SX,(310+Math.Max(u+.65,l-.65))*SY));
        }
        StreamGeometry g=new StreamGeometry();
        using (StreamGeometryContext c=g.Open()) {
            c.BeginFigure(upper[0],true,true);
            for (int i=1;i<upper.Count;i++) c.LineTo(upper[i],true,false);
            for (int i=lower.Count-1;i>=0;i--) c.LineTo(lower[i],true,false);
        }
        g.Freeze(); return g;
    }

    private void DrawIrisCode(DrawingContext dc,double t,double openness) {
        double phase=Clamp((t-2.9)/1.3);
        double envelope=.58*Math.Pow(Math.Sin(Math.PI*phase),.80)*(1-.35*phase);
        if (envelope<.001) return;
        Geometry iris=new EllipseGeometry(new Point(1480*SX,411*SY),53*SX,53*SY);
        Geometry clip=Geometry.Combine(iris,Aperture(openness),GeometryCombineMode.Intersect,Transform.Identity);
        dc.PushClip(clip); dc.PushOpacity(envelope);
        // A continuous vertical terminal stream. Individual rows fade at both rims.
        double cx=1480*SX, cy=411*SY, radius=53*SY;
        double advance=(t-2.9)*27;
        double spacing=6.25;
        for (int row=-9;row<12;row++) {
            double y=cy-radius+(row*spacing+advance)%(radius*2+spacing*4);
            double relative=(y-(cy-radius))/(radius*2);
            double edge=Smooth(relative/.24)*Smooth((1-relative)/.25);
            if (edge<=0) continue;
            string text=(row%3==0 ? "01010100101101" : row%3==1 ? "10110010100101" : "00101101011010");
            FormattedText code=new FormattedText(text,CultureInfo.InvariantCulture,FlowDirection.LeftToRight,mono,5.0,Brush(255,204,213,246),1.0);
            dc.PushOpacity(edge); dc.DrawText(code,new Point(cx-30,y-2.5)); dc.Pop();
        }
        dc.Pop(); dc.Pop();
    }

    private void Text(DrawingContext dc,string value,double x,double y,double size,Color color,bool monospaced) {
        FormattedText text=new FormattedText(value,CultureInfo.InvariantCulture,FlowDirection.LeftToRight,monospaced?mono:sans,size,new SolidColorBrush(color),1.0);
        dc.DrawText(text,new Point(x,y));
    }
    private void DrawInterface(DrawingContext dc,double t) {
        double early=Ease(t,.02,.45);
        dc.PushOpacity(early);
        Text(dc,"+  ChatGPT",40,30,16,Color.FromRgb(223,235,246),false);
        Text(dc,"AI ASSISTANT\nFOR A SMARTER TOMORROW",42,61,7.5,Color.FromRgb(183,198,216),true);
        Text(dc,"CODEX\nDESKTOP SYSTEM 01",950,30,9,Color.FromRgb(200,218,235),true);
        Pen dim=MakePen(Color.FromArgb(135,222,236,248),.55);
        dc.DrawLine(dim,new Point(142,42),new Point(299,42));
        dc.DrawLine(dim,new Point(299,39),new Point(299,45));
        dc.DrawLine(dim,new Point(956,67),new Point(1040,67));
        dc.Pop();
        dc.PushOpacity(Ease(t,.65,1.70));
        Text(dc,"ANALYSIS\nTHINKING\nCREATING",43,120,7.8,Color.FromRgb(196,210,225),true);
        dc.DrawLine(MakePen(Color.FromRgb(193,226,247),.7),new Point(43,157),new Point(64,157));
        dc.DrawLine(dim,new Point(46,205),new Point(46,292));
        dc.Pop();
        double titleReveal=Ease(t,2.4,3.6);
        if (titleReveal>0) {
            Rect bounds=wordmark.Bounds;
            dc.PushClip(new RectangleGeometry(new Rect(bounds.Left-2,bounds.Top-2,(bounds.Width+4)*titleReveal,bounds.Height+4)));
            dc.PushOpacity(.90*titleReveal); dc.DrawGeometry(null,MakePen(Color.FromRgb(239,248,255),.72),wordmark);
            // Keep the requested hollow lettering; a very light metallic fill settles inside it.
            dc.PushOpacity(.13*Ease(t,3.6,4.2)); dc.DrawGeometry(Brush(255,198,218,237),null,wordmark); dc.Pop();
            dc.Pop(); dc.Pop();
        }
        dc.PushOpacity(Ease(t,2.55,3.75));
        Text(dc,"C O D E X   /   P R O F E S S I O N A L   M O D E",66,337,10,Color.FromRgb(214,232,247),true);
        Text(dc,"WELCOME BACK  ·  XINGLI INTERFACE",66,357,7.3,Color.FromRgb(164,189,211),true);
        // A small trailing fringe of light under the wordmark.
        double pulse=.58+.15*Math.Sin(t*1.6);
        dc.PushOpacity(pulse);
        Pen fringe=MakePen(Color.FromRgb(218,239,251),.45);
        dc.DrawLine(fringe,new Point(67,389),new Point(438,389));
        for (int i=0;i<3;i++) {
            double x=397+i*16, length=14+9*Math.Sin(.8*t+i*.8);
            dc.DrawLine(fringe,new Point(x,389),new Point(x,389+length));
            dc.DrawEllipse(Brush(210,218,235,250),null,new Point(x,389+length),.8,.8);
        }
        dc.Pop();
        string status=t<3.0 ? "> initializing interface..." : t<4.2 ? "> synchronizing neural link..." : "> Codex mode ready.";
        if (Waiting) status="> "+LaunchStatus;
        Text(dc,status,66,434,9.5,Color.FromRgb(165,194,214),true);
        double progress=Math.Min(1,t/4.2);
        dc.DrawLine(MakePen(Color.FromArgb(75,166,190,211),.6),new Point(66,459),new Point(346,459));
        dc.DrawLine(MakePen(Color.FromArgb(185,211,234,250),.7),new Point(66,459),new Point(66+280*progress,459));
        dc.Pop();
        dc.PushOpacity(early*.8);
        Text(dc,"YOUR AI COMPANION\nFOR A SMARTER FUTURE",42,555,7.5,Color.FromRgb(173,195,213),true);
        Text(dc,"ESC TO SKIP",500,582,6.8,Color.FromRgb(171,188,206),true);
        dc.DrawLine(dim,new Point(42,544),new Point(139,544));
        dc.Pop();
    }

    private void DrawRain(DrawingContext dc,double t) {
        foreach (Rain drop in drops) {
            double p=(drop.Phase+drop.Cycles*t/8)%1;
            double y=p*(H+64)-32;
            double x=(drop.X+p*12)%W;
            dc.DrawLine(drop.Pen,new Point(x,y),new Point(x-1.7,y+drop.Length));
        }
    }
    public void DrawWallpaper(DrawingContext dc,double t) {
        double phase=t%8;
        double closing=Ease(phase,3.56,3.69), reopening=Ease(phase,3.69,3.98);
        double openness=1-closing*(1-reopening);
        dc.DrawImage(motion.Render(CharacterTexture(t,openness,false),t,motionWidth,motionHeight),new Rect(0,0,W,H));
        DrawRain(dc,t);
    }
    public BitmapSource Snapshot(double t,int width,int height,bool wallpaper) {
        motionWidth=width; motionHeight=height;
        DrawingVisual visual=new DrawingVisual();
        // Export at the target resolution so high-DPI playback retains detail.
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        using (DrawingContext dc=visual.RenderOpen()) {
            dc.PushTransform(new ScaleTransform(width/W,height/H));
            if (wallpaper) DrawWallpaper(dc,t); else DrawBoot(dc,t);
            dc.Pop();
        }
        RenderTargetBitmap image=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);
        image.Render(visual); image.Freeze(); return image;
    }
    public void SaveFrame(double t,string path,int width,int height,bool wallpaper) {
        PngBitmapEncoder png=new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(Snapshot(t,width,height,wallpaper)));
        using (FileStream file=File.Create(path)) png.Save(file);
    }
    public void ExportVideo(string encoder,string output,int fps,int width,int height,double duration,bool wallpaper) {
        ProcessStartInfo info=new ProcessStartInfo(encoder);
        info.Arguments="-hide_banner -loglevel error -y -f rawvideo -pix_fmt bgra -s "+width+"x"+height+
            " -r "+fps+" -i - -an -c:v libx264 -preset slow -crf 10 -pix_fmt yuv420p -movflags +faststart \""+output+"\"";
        info.UseShellExecute=false; info.CreateNoWindow=true; info.RedirectStandardInput=true;
        using (Process encoderProcess=Process.Start(info)) {
            byte[] pixels=new byte[width*height*4];
            using (Stream stream=encoderProcess.StandardInput.BaseStream) {
                int count=(int)Math.Round(duration*fps);
                for (int frame=0;frame<count;frame++) {
                    BitmapSource image=Snapshot(frame/(double)fps,width,height,wallpaper);
                    image.CopyPixels(pixels,width*4,0); stream.Write(pixels,0,pixels.Length);
                    image=null;
                    // Offscreen WPF has no running Application message loop.
                    // Drain deferred native render resources during long exports.
                    // UHD frames carry over twice the QHD native resources.
                    // Release a smaller batch so long offline exports stay
                    // bounded even while the current chat is still running.
                    int releaseBatch=width*height >= 3840*2160 ? 6 : 12;
                    if ((frame+1)%releaseBatch==0) {
                        XingliMotionSurface.DrainDispatcher();
                        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
                        XingliMotionSurface.DrainDispatcher();
                    }
                    if ((frame+1)%60==0) {
                        Console.WriteLine(Path.GetFileName(output)+": "+(frame+1)+"/"+count+" frames");
                    }
                }
            }
            encoderProcess.WaitForExit();
            if (encoderProcess.ExitCode!=0) throw new InvalidOperationException("Video encoder failed with "+encoderProcess.ExitCode);
        }
    }
}
