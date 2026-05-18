```sh
# addon
curl -o /tmp/fteqcc_linux64.zip https://www.fteqcc.org/dl/fteqcc_linux64.zip
sudo unzip -d /usr/local/bin /tmp/fteqcc_linux64.zip fteqcc64
sudo chmod +x /usr/local/bin/fteqcc64

cd hub_addon
FTEQCC=fteqcc64 make clean && FTEQCC=fteqcc64 make

# fte (web)
cd engine
set -gx FTE_TARGET web
source ~/emsdk/emsdk_env.fish
make FTE_TARGET=web makelibs
make -j(nproc) gl-rel LINK_EZHUD=1 LINK_OPENSSL=1
```
