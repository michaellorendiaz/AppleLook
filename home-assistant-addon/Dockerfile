# Home Assistant builds this from the add-on folder alone, so it installs the
# server package from GitHub rather than copying it in.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends git tzdata && rm -rf /var/lib/apt/lists/*
ARG APPLELOOK_REF=main
RUN pip install --no-cache-dir \
    "applelook-server @ git+https://github.com/michaellorendiaz/AppleLook@${APPLELOOK_REF}#subdirectory=server"
# ingress: no login of our own; only Home Assistant's proxy may connect
ENV APPLELOOK_AUTH=ingress APPLELOOK_DATA=/data PYTHONUNBUFFERED=1
CMD ["applelook-server"]
