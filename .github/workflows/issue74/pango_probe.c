#include <glib-object.h>
#include <pango/pangoft2.h>

int main(void) {
	PangoFontMap *font_map = pango_ft2_font_map_new();
	if (font_map == NULL) {
		return 2;
	}

	PangoContext *context = pango_font_map_create_context(font_map);
	if (context == NULL) {
		g_object_unref(font_map);
		return 3;
	}

	g_object_unref(context);
	g_object_unref(font_map);
	return 0;
}
