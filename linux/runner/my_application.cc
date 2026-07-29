#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

struct TanukiWindowState {
  GtkWindow* window;
  GtkWidget* title_bar;
  gboolean fullscreen;
};

static void tanuki_window_state_free(gpointer data) {
  TanukiWindowState* state = static_cast<TanukiWindowState*>(data);
  if (state->title_bar != nullptr) {
    g_object_unref(state->title_bar);
  }
  g_free(state);
}

static void log_window_state(const gchar* label, GtkWindow* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  GdkWindowState state =
      gdk_window == nullptr ? static_cast<GdkWindowState>(0)
                            : gdk_window_get_state(gdk_window);
  gint width = 0;
  gint height = 0;
  gtk_window_get_size(window, &width, &height);
  g_print(
      "TanukiFullscreen: %s size=%dx%d fullscreen=%d maximized=%d decorated=%d "
      "visible=%d\n",
      label, width, height, (state & GDK_WINDOW_STATE_FULLSCREEN) != 0,
      (state & GDK_WINDOW_STATE_MAXIMIZED) != 0,
      gtk_window_get_decorated(window),
      gtk_widget_get_visible(GTK_WIDGET(window)));
}

static gboolean log_window_state_after_fullscreen(gpointer user_data) {
  TanukiWindowState* state = static_cast<TanukiWindowState*>(user_data);
  if (state != nullptr && state->window != nullptr) {
    log_window_state("after-timeout", state->window);
  }
  return G_SOURCE_REMOVE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void set_real_fullscreen(TanukiWindowState* state, gboolean enabled) {
  if (state == nullptr || state->window == nullptr ||
      state->fullscreen == enabled) {
    if (state != nullptr && state->window != nullptr) {
      log_window_state("skip-same-state", state->window);
    }
    return;
  }

  log_window_state(enabled ? "before-enter" : "before-exit", state->window);
  if (enabled) {
    state->fullscreen = TRUE;
    if (state->title_bar != nullptr) {
      gtk_widget_hide(state->title_bar);
    }
    gtk_window_unmaximize(state->window);
    gtk_window_set_decorated(state->window, FALSE);
    gtk_window_set_keep_above(state->window, TRUE);
    gtk_window_fullscreen(state->window);
    log_window_state("after-enter-request", state->window);
    g_timeout_add(500, log_window_state_after_fullscreen, state);
    return;
  }

  state->fullscreen = FALSE;
  gtk_window_unfullscreen(state->window);
  gtk_window_set_keep_above(state->window, FALSE);
  gtk_window_set_decorated(state->window, TRUE);
  if (state->title_bar != nullptr) {
    gtk_widget_show(state->title_bar);
  }
  gtk_window_maximize(state->window);
  log_window_state("after-exit-request", state->window);
  g_timeout_add(500, log_window_state_after_fullscreen, state);
}

static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  (void)channel;
  const gchar* method = fl_method_call_get_name(method_call);
  TanukiWindowState* state = static_cast<TanukiWindowState*>(user_data);

  if (g_strcmp0(method, "setFullscreen") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    gboolean enabled =
        args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(args);
    g_print("TanukiFullscreen: method setFullscreen enabled=%d\n", enabled);
    set_real_fullscreen(state, enabled);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(method_call, response, nullptr);
}

static bool can_create_opengl_context() {
  GtkWidget* probe_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(probe_window), 1, 1);
  gtk_widget_realize(probe_window);

  GdkWindow* window = gtk_widget_get_window(probe_window);
  if (window == nullptr) {
    g_warning("OpenGL renderer unavailable; using software renderer: no GDK window");
    gtk_widget_destroy(probe_window);
    return false;
  }

  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkGLContext) context =
      gdk_window_create_gl_context(window, &error);
  if (context == nullptr) {
    g_warning("OpenGL renderer unavailable; using software renderer: %s",
              error != nullptr ? error->message : "unknown error");
    gtk_widget_destroy(probe_window);
    return false;
  }

  if (!gdk_gl_context_realize(context, &error)) {
    g_warning("OpenGL renderer unavailable; using software renderer: %s",
              error != nullptr ? error->message : "unknown error");
    gtk_widget_destroy(probe_window);
    return false;
  }

  gtk_widget_destroy(probe_window);
  return true;
}

static void configure_flutter_linux_renderer() {
  const gchar* renderer = g_getenv("FLUTTER_LINUX_RENDERER");
  if (renderer != nullptr && renderer[0] != '\0') {
    return;
  }

  if (!can_create_opengl_context()) {
    g_setenv("FLUTTER_LINUX_RENDERER", "software", TRUE);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  GtkWidget* title_bar = nullptr;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Tanuki");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    title_bar = GTK_WIDGET(header_bar);
    gtk_window_set_titlebar(window, title_bar);
  } else {
    gtk_window_set_title(window, "Tanuki");
  }

  gtk_window_set_default_size(window, 1280, 720);
  configure_flutter_linux_renderer();

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));

  // Desktop WebViews are native GTK children positioned above the Flutter
  // surface. GtkOverlay keeps them embedded in this application window.
  GtkWidget* overlay = gtk_overlay_new();
  gtk_widget_show(overlay);
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), overlay);
  gtk_window_maximize(window);

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  TanukiWindowState* window_state =
      static_cast<TanukiWindowState*>(g_malloc0(sizeof(TanukiWindowState)));
  window_state->window = window;
  window_state->title_bar =
      title_bar == nullptr ? nullptr : GTK_WIDGET(g_object_ref(title_bar));
  window_state->fullscreen = FALSE;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "tanuki/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      window_channel, window_method_call_cb, window_state, nullptr);
  g_object_set_data_full(G_OBJECT(window), "tanuki-window-channel",
                         window_channel, g_object_unref);
  g_object_set_data_full(G_OBJECT(window), "tanuki-window-state", window_state,
                         tanuki_window_state_free);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
