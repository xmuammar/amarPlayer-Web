from pathlib import Path
import importlib.util

def test_project_files_exist():
    root = Path(__file__).resolve().parents[1]
    for name in [
        "server.py", "index.html", "service-worker.js",
        "js/app.js", "js/db.js", "js/audio-engine.js",
        "css/main.css", "manifest.webmanifest"
    ]:
        assert (root / name).exists(), name

def test_server_imports():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("amar_server", root / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.app.title.startswith("amarPlayer")
