#include <libintl.h>
#include <stddef.h>

int main(void) {
	const char *translated = gettext("gui-issue-74");
	return translated == NULL;
}
