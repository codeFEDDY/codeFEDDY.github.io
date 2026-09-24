#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *message = "GO FURTHEST.";

    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], "--Message") == 0) {
            message = argv[i + 1];
            ++i;
        }
    }

    printf("QUILLGEIST_LITE_C_OK\n");
    printf("message=%s\n", message);
    return 0;
}
