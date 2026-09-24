import argparse
import platform
import sys

parser = argparse.ArgumentParser(description="Quillgeist Lite Python runtime check")
parser.add_argument("--Message", default="GO FURTHEST.")
args = parser.parse_args()

print("QUILLGEIST_LITE_PYTHON_OK")
print("python=" + sys.version.split()[0])
print("platform=" + platform.platform())
print("message=" + args.Message)
