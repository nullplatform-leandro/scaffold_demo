# Replaces the Dockerfile the repository inherited from the "Any technology"
# template, which ran an http-echo image. That one has to go: the CI that came
# with the same template builds whatever Dockerfile is at the root and pushes it
# as the docker-image asset, so leaving it in place would deploy the echo server
# no matter what else the scaffolding wrote.

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

WORKDIR /src

COPY global.json Directory.Build.props ./
COPY src/ src/

RUN dotnet publish src/__APP_NAME__/__APP_NAME__.csproj --configuration Release --output /app


FROM mcr.microsoft.com/dotnet/aspnet:8.0

WORKDIR /app

COPY --from=build /app .

# 8080, because that is the port the "Any technology" template exposed and the
# one the scope health-checks. ASP.NET would otherwise pick 5000 and the build
# would pass while the deployment failed.
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "__APP_NAME__.dll"]
