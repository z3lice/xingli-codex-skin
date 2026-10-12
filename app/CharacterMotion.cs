using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using System.Windows.Threading;

// A view-dependent 3D depth surface built from the original portrait pixels.
// It supplies depth/parallax and continuous joint motion, not a 360-degree model.
// Bake the eye atlas, iris clipping/code, and contours into the input texture
// before this pass. Keep the UI, rain, and other screen-space graphics outside it.
public sealed class XingliMotionSurface {
    public const double Width = 1080.0, Height = 608.0, LoopSeconds = 8.0;
    // Four times the old triangle density smooths broad joint deformation at
    // UHD output without changing the portrait's UVs, motion or facial anchors.
    public const int GridColumns = 140, GridRows = 90;
    private const double Padding = 18.0;
    private readonly Viewport3D viewport;
    private readonly MeshGeometry3D mesh;
    private readonly GeometryModel3D model;
    private readonly ImageBrush textureBrush;
    private readonly double[] sourceX, sourceY;
    private int lastWidth, lastHeight;
    public double LastRenderMilliseconds { get; private set; }
    public int VertexCount { get { return sourceX.Length; } }
    public int TriangleCount { get { return GridColumns * GridRows * 2; } }

    public XingliMotionSurface() {
        int count = (GridColumns + 1) * (GridRows + 1);
        sourceX = new double[count]; sourceY = new double[count];
        PointCollection coordinates = new PointCollection(count);
        Int32Collection indices = new Int32Collection(GridColumns * GridRows * 6);
        Point3DCollection positions = new Point3DCollection(count);
        for (int row = 0; row <= GridRows; row++) {
            double y = -Padding + (Height + 2 * Padding) * row / GridRows;
            for (int column = 0; column <= GridColumns; column++) {
                double x = -Padding + (Width + 2 * Padding) * column / GridColumns;
                int index = row * (GridColumns + 1) + column;
                sourceX[index] = x; sourceY[index] = y;
                coordinates.Add(new Point(Clamp(x / Width), Clamp(y / Height)));
                positions.Add(Position(x, y, 0));
                if (column < GridColumns && row < GridRows) {
                    int below = index + GridColumns + 1;
                    // Counterclockwise normals face the camera on the +Z side.
                    indices.Add(index); indices.Add(below); indices.Add(index + 1);
                    indices.Add(index + 1); indices.Add(below); indices.Add(below + 1);
                }
            }
        }
        coordinates.Freeze(); indices.Freeze(); positions.Freeze();
        mesh = new MeshGeometry3D();
        mesh.Positions = positions; mesh.TextureCoordinates = coordinates;
        mesh.TriangleIndices = indices;
        textureBrush = new ImageBrush();
        textureBrush.Stretch = Stretch.Fill;
        textureBrush.TileMode = TileMode.None;
        textureBrush.ViewboxUnits = BrushMappingMode.RelativeToBoundingBox;
        textureBrush.Viewbox = new Rect(0, 0, 1, 1);
        // WPF EmissiveMaterial alone loses alpha in offscreen 3D rendering.
        // A white ambient-lit diffuse pass keeps the original texture colour
        // and coverage. It tested pixel-identical to black diffuse + emissive,
        // with roughly half the rasterization time and no specular highlights.
        DiffuseMaterial material = new DiffuseMaterial(textureBrush);
        material.Color = Colors.White; material.AmbientColor = Colors.White;
        model = new GeometryModel3D(mesh, material);
        Model3DGroup group = new Model3DGroup();
        group.Children.Add(new AmbientLight(Colors.White)); group.Children.Add(model);
        ModelVisual3D visual = new ModelVisual3D(); visual.Content = group;
        viewport = new Viewport3D();
        viewport.IsHitTestVisible = false; viewport.ClipToBounds = false;
        viewport.Camera = new OrthographicCamera(
            new Point3D(Width / 2, -Height / 2, 1600),
            new Vector3D(0, 0, -1), new Vector3D(0, 1, 0), Width);
        viewport.Children.Add(visual);
        RenderOptions.SetBitmapScalingMode(viewport, BitmapScalingMode.HighQuality);
    }

    private static double Clamp(double value) { return Math.Max(0, Math.Min(1, value)); }
    private static double Smooth(double value) {
        value = Clamp(value); return value * value * (3 - 2 * value);
    }
    private static double Gaussian(double x, double center, double radius) {
        double d = (x - center) / radius; return Math.Exp(-d * d * .5);
    }
    private static double Phase(double t) {
        return 2 * Math.PI * ((t % LoopSeconds + LoopSeconds) % LoopSeconds) / LoopSeconds;
    }
    private static double LagWave(double phase, double lag) {
        // Closed periodic motion with both position and derivative continuous.
        // At t=0/8 every point is exactly at the original portrait position.
        return (Math.Sin(phase - lag) + Math.Sin(lag)) / (1 + Math.Abs(Math.Sin(lag)));
    }
    private static double Silhouette(double y) {
        // Approximate the large rear-hair silhouette; the black left side stays
        // fixed, while the dark gaps between fine hairs deform with their mass.
        return 558 - .29 * Math.Max(0, y - 125);
    }

    private static Point3D Position(double x, double y, double t) {
        double phase = Phase(t), breath = Math.Sin(phase);
        double subject = Smooth((x - Silhouette(y) + 34) / 112);
        if (subject <= 0) return new Point3D(x, -y, 0);
        double face = Gaussian(x, 1030, 185) * Gaussian(y, 300, 205);
        double head = Smooth((x - 550) / 190) * (1 - Smooth((y - 403) / 170));
        double chest = Smooth((y - 355) / 215) * Smooth((x - 545) / 180);
        double backHair = (1 - Smooth((x - 754) / 102)) * Smooth((y - 125) / 240);
        double frontHair = Smooth((x - 768) / 105) * Smooth((y - 380) / 165);
        // Head/cheek sit forward; hair masses sit farther back. Orthographic
        // projection means these depths cause no distortion in the rest pose.
        double depth = subject * (14 + 70 * face + 16 * head - 10 * backHair);
        double px = x, py = -y, pz = depth;

        // One small rigid head motion keeps facial features, iris and eyelashes
        // together. Rotation through real depth adds volume-dependent parallax.
        double yaw = .0120 * breath;
        double pitch = .0060 * breath;
        double roll = .0070 * breath;
        double dx = x - 942, dy = -y + 283, dz = depth - 32;
        double rx = Math.Cos(yaw) * dx + Math.Sin(yaw) * dz;
        double rz = -Math.Sin(yaw) * dx + Math.Cos(yaw) * dz;
        double ry = Math.Cos(pitch) * dy - Math.Sin(pitch) * rz;
        rz = Math.Sin(pitch) * dy + Math.Cos(pitch) * rz;
        double finalX = Math.Cos(roll) * rx - Math.Sin(roll) * ry;
        double finalY = Math.Sin(roll) * rx + Math.Cos(roll) * ry;
        px += head * (finalX - dx + 1.60 * breath);
        py += head * (finalY - dy + 3.60 * breath);
        pz += head * (rz - dz);
        // Thorax rises as the head settles; this is translation/depth breathing,
        // not zooming the whole portrait or pulling the face into a local scale.
        py += chest * 4.20 * breath;
        pz += chest * 4.50 * breath;

        // The visible pointed ear follows the head at its root. Its tip has a
        // small delayed bend, never a separate floating or sliding ear layer.
        double ear = Gaussian(x, 698, 60) * Gaussian(y, 256, 35);
        double earTip = ear * Clamp((768 - x) / 111);
        double earWave = LagWave(phase, .47);
        px -= earTip * 20.00 * earWave;
        py += earTip * 11.50 * earWave;
        pz += earTip * 8.00 * earWave;

        // Broad bundles move with separate inertia. Weight normalization avoids
        // additive over-bending where neighbouring bundles overlap.
        double g1 = Gaussian(x, 687 - .40 * Math.Max(0, y - 150), 63);
        double g2 = Gaussian(x, 698 - .57 * Math.Max(0, y - 135), 62);
        double g3 = Gaussian(x, 771 - .25 * Math.Max(0, y - 145), 75);
        double sum = Math.Max(1, g1 + g2 + g3);
        double tail = Smooth((y - 175) / 330);
        double hairX = (g1 * 14.0 * LagWave(phase, .40 + .45 * tail)
                      + g2 * 18.0 * LagWave(phase, .78 + .35 * tail)
                      - g3 * 11.0 * LagWave(phase, .56 + .30 * tail)) / sum;
        px += backHair * hairX;
        py += backHair * 3.60 * LagWave(phase, .95);
        pz += backHair * 6.0 * LagWave(phase, .72);
        px += frontHair * 7.0 * LagWave(phase, .60);
        py += frontHair * 2.60 * LagWave(phase, .84);
        // All deformation tapers to zero before the fixed background. Padding
        // supplies texture overscan for cropped face/hair edges at the right.
        return new Point3D(x + subject * (px - x), -y + subject * (py + y),
                           depth + subject * (pz - depth));
    }

    // Useful for overlays/QA anchors, but baking them into the texture is more
    // accurate because the same triangle interpolation then applies to all.
    public Point MapPoint(Point source, double t) {
        Point3D point = Position(source.X, source.Y, t);
        return new Point(point.X, -point.Y);
    }

    public BitmapSource Render(BitmapSource texture, double t, int width, int height) {
        if (texture == null) throw new ArgumentNullException("texture");
        if (width <= 0 || height <= 0) throw new ArgumentOutOfRangeException("width");
        Stopwatch timer = Stopwatch.StartNew();
        textureBrush.ImageSource = texture;
        // The scene's 1080x608 design aspect is slightly different from exact
        // 16:9 output. Correct only the projection, keeping the rest-pose UVs
        // exactly aligned with a 2D drawing into the same output rectangle.
        double projectionScaleY = Width * height / width / Height;
        Point3D[] values = new Point3D[sourceX.Length];
        for (int i = 0; i < values.Length; i++) {
            Point3D point = Position(sourceX[i], sourceY[i], t);
            values[i] = new Point3D(point.X, point.Y * projectionScaleY, point.Z);
        }
        // One frozen collection replacement avoids thousands of change events
        // on a mesh still attached to the visual tree.
        Point3DCollection positions = new Point3DCollection(values); positions.Freeze();
        mesh.Positions = positions;
        if (lastWidth != width || lastHeight != height) {
            ((OrthographicCamera)viewport.Camera).Position =
                new Point3D(Width / 2, -Height / 2 * projectionScaleY, 1600);
            viewport.Width = width; viewport.Height = height;
            viewport.Measure(new Size(width, height));
            viewport.Arrange(new Rect(0, 0, width, height)); viewport.UpdateLayout();
            lastWidth = width; lastHeight = height;
        }
        RenderTargetBitmap result = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        try {
            result.Render(viewport); result.Freeze();
        } finally {
            // An offline export repeatedly changes this retained visual tree.
            // Drop the source as soon as pixels are complete so it cannot keep
            // an entire previous-frame render target alive between frames.
            textureBrush.ImageSource = null;
        }
        LastRenderMilliseconds = timer.Elapsed.TotalMilliseconds;
        return result;
    }

    // Offscreen loops do not enter Application.Run, so WPF's queued render
    // resource updates/releases otherwise accumulate even when managed frames
    // are collected. Call before and after a bounded GC batch in the exporter.
    public static void DrainDispatcher() {
        Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
        if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished) return;
        DispatcherFrame frame = new DispatcherFrame();
        dispatcher.BeginInvoke(DispatcherPriority.ContextIdle,
            new DispatcherOperationCallback(delegate(object state) {
                ((DispatcherFrame)state).Continue = false; return null;
            }), frame);
        Dispatcher.PushFrame(frame);
    }

    public void DrawTo(DrawingContext dc, BitmapSource texture, double t, int width, int height) {
        dc.DrawImage(Render(texture, t, width, height), new Rect(0, 0, Width, Height));
    }
}
