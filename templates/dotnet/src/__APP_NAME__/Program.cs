namespace __APP_NAME__;

public static class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);
        var app = builder.Build();

        // Scaffolded for the nullplatform application __APPLICATION_SLUG__,
        // in the repository __REPOSITORY_NAME__.
        app.MapGet("/", () => "__APPLICATION_SLUG__ is up");
        app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

        app.Run();
    }
}
