#ifndef GUI_PORTAL_LINUX_TEST_H
#define GUI_PORTAL_LINUX_TEST_H

#ifdef GUI_PORTAL_TESTING
int gui_portal_test_build_handle_path_equals(
    const char* unique_name,
    const char* token,
    const char* expected);
int gui_portal_test_build_handle_path_rejects_empty_sender(void);
int gui_portal_test_parse_reply_handle_equals(
    const char* returned_handle,
    const char* expected);
int gui_portal_test_parse_reply_handle_rejects_empty_reply(void);
int gui_portal_test_parse_reply_handle_rejects_string(void);
#endif

#endif
