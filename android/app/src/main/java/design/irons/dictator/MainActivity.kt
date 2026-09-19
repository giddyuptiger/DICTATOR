package design.irons.dictator

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.MaterialTheme.colorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.os.Build

/**
 * Setup / onboarding screen. Three jobs:
 *   1. Enable the Dictator keyboard in system settings.
 *   2. Grant the RECORD_AUDIO runtime permission (an IME cannot request runtime
 *      permissions itself, so it is granted here in a normal Activity).
 *   3. Pick the dictation mode and read a short "how to use" note.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { DictatorTheme { SetupScreen() } }
    }
}

@Composable
private fun DictatorTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    // Material You dynamic color on Android 12+, with a plain fallback below it.
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme) {
        Surface(modifier = Modifier.fillMaxSize()) { content() }
    }
}

@Composable
private fun SetupScreen() {
    val context = LocalContext.current

    var micGranted by remember {
        mutableStateOf(
            ContextCompat_checkSelfPermission(context, Manifest.permission.RECORD_AUDIO),
        )
    }
    var selectedMode by remember { mutableStateOf(ToneProfiles.currentMode(context)) }

    val micLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> micGranted = granted }

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(20.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                "Dictator",
                fontSize = 30.sp,
                fontWeight = FontWeight.Bold,
                color = colorScheme.onSurface,
            )
            Text(
                "A dictation keyboard. Hold the mic, speak, and it types clean text.",
                fontSize = 15.sp,
                color = colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(24.dp))

            // Step 1: enable the keyboard.
            StepCard(number = "1", title = "Enable the keyboard") {
                Text(
                    "Open system keyboard settings and switch Dictator on. Then tap the " +
                        "globe or keyboard icon while typing to select it.",
                    fontSize = 14.sp,
                    color = colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(10.dp))
                Button(onClick = {
                    context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                }) { Text("Open keyboard settings") }
            }

            Spacer(Modifier.height(16.dp))

            // Step 2: microphone permission.
            StepCard(number = "2", title = "Allow the microphone") {
                Text(
                    if (micGranted) "Microphone access granted."
                    else "Dictator records audio to transcribe it. Grant microphone access.",
                    fontSize = 14.sp,
                    color = colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = { micLauncher.launch(Manifest.permission.RECORD_AUDIO) },
                    enabled = !micGranted,
                ) { Text(if (micGranted) "Granted" else "Grant microphone access") }
            }

            Spacer(Modifier.height(16.dp))

            // Step 3: mode picker.
            StepCard(number = "3", title = "Choose a style") {
                Text(
                    "The style shapes how your words come out. You can also change it " +
                        "from the keyboard by tapping the style pill.",
                    fontSize = 14.sp,
                    color = colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(6.dp))
                DictationMode.all.forEach { mode ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = mode == selectedMode,
                                onClick = {
                                    selectedMode = mode
                                    ToneProfiles.setMode(context, mode)
                                },
                            )
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertical,
                    ) {
                        RadioButton(
                            selected = mode == selectedMode,
                            onClick = {
                                selectedMode = mode
                                ToneProfiles.setMode(context, mode)
                            },
                        )
                        Spacer(Modifier.height(0.dp))
                        Text(
                            mode.displayName,
                            fontSize = 16.sp,
                            color = colorScheme.onSurface,
                            modifier = Modifier.padding(start = 8.dp),
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // How to use.
            StepCard(number = "?", title = "How to use") {
                Text(
                    "• Tap a text field and switch to the Dictator keyboard.\n" +
                        "• Hold the mic and speak, then release — or tap once to start " +
                        "and tap again to stop.\n" +
                        "• Your speech is transcribed and cleaned up, then typed into the field.\n" +
                        "• Transcription runs in the cloud (v1), so an internet connection is needed.",
                    fontSize = 14.sp,
                    color = colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun StepCard(number: String, title: String, content: @Composable () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertical) {
                Text(
                    number,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = colorScheme.primary,
                )
                Text(
                    title,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colorScheme.onSurface,
                    modifier = Modifier.padding(start = 10.dp),
                )
            }
            Spacer(Modifier.height(8.dp))
            content()
        }
    }
}

/** Small wrapper so the permission check reads cleanly in the composable above. */
private fun ContextCompat_checkSelfPermission(context: Context, permission: String): Boolean =
    context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
