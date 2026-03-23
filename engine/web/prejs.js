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

const CONTENT_TYPE_TO_EXTENSION = {
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

const KNOWN_EXTENSIONS = new Set([
	".ase",
	".bsp",
	".cfg",
	".dem",
	".dm2",
	".dpm",
	".fmf",
	".glb",
	".gltf",
	".iqm",
	".kpf",
	".lwo",
	".map",
	".md2",
	".md3",
	".mdl",
	".mvd",
	".obj",
	".pak",
	".pk3",
	".pk4",
	".psk",
	".qtv",
	".qwd",
	".rc",
	".spr",
	".spr2",
	".vvm",
	".wad",
	".zip",
	".zym",
]);

function hasKnownExtension(fileName) {
	const dot = fileName.lastIndexOf(".");
	if (dot < 0) return false;
	return KNOWN_EXTENSIONS.has(fileName.substring(dot).toLowerCase());
}

function registerBuffer(fileName, arrayBuffer) {
	const buf = FTEH.h[_emscriptenfte_buf_createfromarraybuf(arrayBuffer)];
	buf.n = fileName;
	FTEH.f[fileName] = buf;
}

function loadFileFromUrl(fileName, url) {
	addRunDependency(fileName);
	fetch(url)
		.then((response) => {
			if (!response.ok) throw new Error(`HTTP ${response.status}`);
			if (!hasKnownExtension(fileName)) {
				const mimeType = (response.headers.get("content-type") || "")
					.split(";")[0]
					.trim()
					.toLowerCase();
				const extension = CONTENT_TYPE_TO_EXTENSION[mimeType];
				if (extension) fileName += extension;
			}
			return response.arrayBuffer();
		})
		.then((buffer) => registerBuffer(fileName, buffer))
		.catch(() => {})
		.finally(() => removeRunDependency(fileName));
}

function loadFileFromPromise(fileName, promise) {
	addRunDependency(fileName);
	promise
		.then((buffer) => registerBuffer(fileName, buffer))
		.catch((reason) => console.log(reason))
		.finally(() => removeRunDependency(fileName));
}

Module.loadcachedfiles = () => {
	addRunDependency("loadcachedfiles");
	try {
		caches
			.open("user")
			.then((cache) => {
				Module.cache = cache;
				return cache.keys();
			})
			.then((keys) => {
				const validKeys = keys.filter((key) => key.url.includes("/_/"));
				return Promise.all(
					validKeys.map((key) => {
						const fileName = key.url.substring(key.url.indexOf("/_/") + 3);
						addRunDependency(fileName);
						return Module.cache
							.match(key)
							.then((response) => response.arrayBuffer())
							.then((buffer) => registerBuffer(fileName, buffer))
							.finally(() => removeRunDependency(fileName));
					}),
				);
			})
			.finally(() => removeRunDependency("loadcachedfiles"));
	} catch (_e) {
		removeRunDependency("loadcachedfiles");
	}
};

Module.preRun = Module.loadcachedfiles;

if (Module.files !== undefined && Object.keys(Module.files).length > 0) {
	Module.preRun = () => {
		Module.loadcachedfiles();

		for (const [fileName, fileData] of Object.entries(Module.files)) {
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
	const { protocol, host, pathname, hash } = window.location;
	let manifestUrl = `${protocol}//${host}${pathname}`;
	manifestUrl += pathname.endsWith("/") ? "index.fmf" : ".fmf";
	Module.manifest = manifestUrl;

	if (hash !== "") Module.manifest = hash.substring(1);
}

if (!Module.arguments) {
	Module.arguments = [];

	const COMMANDS_WITH_VALUE = [
		"+sv_port_rtc",
		"+connect",
		"+join",
		"+observe",
		"+qtvplay",
	];

	const queryString = decodeURIComponent(window.location.search.substring(1));
	if (queryString !== "") {
		const args = queryString.split(" ");
		for (let i = 0; i < args.length; i++) {
			if (args[i] === "-manifest") {
				Module.manifest = undefined;
			} else if (COMMANDS_WITH_VALUE.includes(args[i]) && i + 1 < args.length) {
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
