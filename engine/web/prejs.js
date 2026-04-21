FTEH = { h: [], f: {} };
FTE_SW = null;

if (!Module.canvas) {
	Module.canvas = document.getElementById("canvas");
	if (!Module.canvas) {
		console.log("No canvas element defined yet.");
		Module.canvas = document.createElement("canvas");
		Module.canvas.style.width = "100%";
		Module.canvas.style.height = "100%";
		document.body.appendChild(Module.canvas);
	}
}

var CONTENT_TYPE_TO_EXTENSION = {
	"application/gltf-binary": ".glb",
	"application/x-ftemanifest": ".fmf",
	"application/x-fteplugin": ".fmf",
	"application/x-multiviewdemo": ".mvd",
	"application/x-qtv": ".qtv",
	"application/x-quake-demo": ".dem",
	"application/x-quakeworld-demo": ".qwd",
	"application/zip": ".zip",
	"model/gltf+json": ".gltf",
	"model/gltf-binary": ".glb",
	"text/x-quaketvident": ".qtv",
};

var KNOWN_EXTENSIONS = {
	".ase": 1,
	".bsp": 1,
	".cfg": 1,
	".dem": 1,
	".dm2": 1,
	".dpm": 1,
	".fmf": 1,
	".glb": 1,
	".gltf": 1,
	".iqm": 1,
	".kpf": 1,
	".lwo": 1,
	".map": 1,
	".md2": 1,
	".md3": 1,
	".mdl": 1,
	".mvd": 1,
	".obj": 1,
	".pak": 1,
	".pk3": 1,
	".pk4": 1,
	".psk": 1,
	".qtv": 1,
	".qwd": 1,
	".rc": 1,
	".spr": 1,
	".spr2": 1,
	".vvm": 1,
	".wad": 1,
	".zip": 1,
	".zym": 1,
};

function hasKnownExtension(fileName) {
	var dot = fileName.lastIndexOf(".");
	if (dot < 0) return false;
	return KNOWN_EXTENSIONS[fileName.substring(dot).toLowerCase()] === 1;
}

function registerBuffer(fileName, arrayBuffer) {
	var buf = FTEH.h[_emscriptenfte_buf_createfromarraybuf(arrayBuffer)];
	buf.n = fileName;
	FTEH.f[fileName] = buf;
}
Module.registerBuffer = registerBuffer;

async function loadTexture_(vfsPath, source) {
	var identifier = vfsPath
		.replace(/^[^/]+\//, "")
		.replace(/\.(png|jpe?g|tga|webp|pcx)$/i, "");
	var buf;
	if (typeof source === "string") {
		if (!/^https?:\/\//i.test(source))
			throw new Error("loadTexture: URL must start with http:// or https://");
		var res = await fetch(source);
		if (!res.ok)
			throw new Error("loadTexture: fetch " + source + ": " + res.status);
		buf = await res.arrayBuffer();
	} else if (source instanceof ArrayBuffer) {
		buf = source;
	} else if (ArrayBuffer.isView(source)) {
		buf = source.buffer;
	} else if (source instanceof Blob) {
		buf = await source.arrayBuffer();
	} else {
		throw new Error("loadTexture: source must be http(s) URL, ArrayBuffer, TypedArray, or Blob");
	}
	registerBuffer(vfsPath, buf);
	FTEC.cbufadd("r_reloadtexture " + identifier + "\n");
}

var loadTextureThrottleState = {};
Module.loadTexture = function (vfsPath, source, intervalMs) {
	intervalMs = intervalMs || 50;
	var state =
		loadTextureThrottleState[vfsPath] ||
		(loadTextureThrottleState[vfsPath] = { lastRun: 0, timer: null, latest: null });
	state.latest = source;
	if (state.timer) return;
	var wait = Math.max(0, intervalMs - (Date.now() - state.lastRun));
	state.timer = setTimeout(function () {
		var src = state.latest;
		state.latest = null;
		state.timer = null;
		state.lastRun = Date.now();
		loadTexture_(vfsPath, src);
	}, wait);
};

function loadFileFromUrl(fileName, url) {
	addRunDependency(fileName);
	fetch(url)
		.then(function (response) {
			if (!response.ok) throw new Error("HTTP " + response.status);
			if (!hasKnownExtension(fileName)) {
				var mimeType = (response.headers.get("content-type") || "")
					.split(";")[0]
					.trim()
					.toLowerCase();
				var extension = CONTENT_TYPE_TO_EXTENSION[mimeType];
				if (extension) fileName += extension;
			}
			return response.arrayBuffer();
		})
		.then(function (buffer) {
			registerBuffer(fileName, buffer);
		})
		.catch(function () {})
		.finally(function () {
			removeRunDependency(fileName);
		});
}

function loadFileFromPromise(fileName, promise) {
	addRunDependency(fileName);
	promise
		.then(function (buffer) {
			registerBuffer(fileName, buffer);
		})
		.catch(function (reason) {
			console.log(reason);
		})
		.finally(function () {
			removeRunDependency(fileName);
		});
}

Module.loadcachedfiles = function () {
	addRunDependency("loadcachedfiles");
	try {
		caches
			.open("user")
			.then(function (cache) {
				Module.cache = cache;
				return cache.keys();
			})
			.then(function (keys) {
				var validKeys = keys.filter(function (key) {
					return key.url.indexOf("/_/") >= 0;
				});
				return Promise.all(
					validKeys.map(function (key) {
						var fileName = key.url.substring(key.url.indexOf("/_/") + 3);
						addRunDependency(fileName);
						return Module.cache
							.match(key)
							.then(function (response) {
								return response.arrayBuffer();
							})
							.then(function (buffer) {
								registerBuffer(fileName, buffer);
							})
							.finally(function () {
								removeRunDependency(fileName);
							});
					}),
				);
			})
			.finally(function () {
				removeRunDependency("loadcachedfiles");
			});
	} catch (_e) {
		removeRunDependency("loadcachedfiles");
	}
};

Module.preRun = Module.loadcachedfiles;

if (Module.files !== undefined && Object.keys(Module.files).length > 0) {
	Module.preRun = function () {
		Module.loadcachedfiles();

		var names = Object.keys(Module.files);
		for (var i = 0; i < names.length; i++) {
			var fileName = names[i];
			var fileData = Module.files[fileName];
			if (typeof fileData === "string") {
				loadFileFromUrl(fileName, fileData);
			} else if (typeof fileData.then === "function") {
				loadFileFromPromise(fileName, fileData);
			} else {
				registerBuffer(fileName, fileData);
			}
		}
	};
} else if (!Module.manifest) {
	var manifestUrl =
		window.location.protocol +
		"//" +
		window.location.host +
		window.location.pathname;
	manifestUrl +=
		window.location.pathname.charAt(window.location.pathname.length - 1) === "/"
			? "index.fmf"
			: ".fmf";
	Module.manifest = manifestUrl;

	if (window.location.hash !== "")
		Module.manifest = window.location.hash.substring(1);
}

if (!Module.arguments) {
	Module.arguments = [];

	var COMMANDS_WITH_VALUE = [
		"+connect",
		"+join",
		"+observe",
		"+playdemo",
		"+qtvplay",
		"+sv_port_rtc",
	];

	var queryString = decodeURIComponent(window.location.search.substring(1));
	if (queryString !== "") {
		var args = queryString.split(" ");
		for (var i = 0; i < args.length; i++) {
			if (args[i] === "-manifest") {
				Module.manifest = undefined;
			} else if (
				COMMANDS_WITH_VALUE.indexOf(args[i]) >= 0 &&
				i + 1 < args.length
			) {
				Module.arguments.push(args[i], args[i + 1]);
				i++;
			} else if (!document.referrer) {
				// ignore args from referrers to protect against malicious args
				Module.arguments.push(args[i]);
			}
		}
	}

	if (Module.manifest !== undefined)
		Module.arguments.push("-manifest", Module.manifest);

	// allow registerProtocolHandler to pass args via URL
	Module.mayregisterscemes = true;
}
