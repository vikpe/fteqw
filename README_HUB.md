```sh
# addon
cd hub_addon
FTEQCC=fteqcc64 make clean && FTEQCC=fteqcc64 make

# fte (web)
set -gx FTE_TARGET web
source ~/emsdk/emsdk_env.fish
make -j(nproc) gl-rel LINK_EZHUD=1 LINK_OPENSSL=1
```
