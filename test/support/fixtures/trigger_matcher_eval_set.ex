defmodule Alethea.TriggerMatcherEvalSet do
  @moduledoc """
  Synthetic Spanish evaluation set for reactive trigger matching (#449, S2).

  Contains realistic synthetic clinical cases in Spanish:
    - Clear matches: message clearly describes the condition (probability >= 0.7)
    - Near-misses: related or adjacent topic but condition not met (probability < 0.7)
    - Multi-trigger: message touches multiple triggers, highest probability >= 0.7 wins
    - No match: message is completely unrelated to any candidate trigger (probability <= 0.1)

  All data is synthetic; no real patient PHI is used.
  """

  @type eval_case :: %{
          id: atom(),
          category: :clear_match | :near_miss | :multi_trigger | :no_match,
          description: String.t(),
          patient_message: String.t(),
          candidates: [
            %{
              id: binary(),
              condition: String.t(),
              approved_text: String.t(),
              mock_noul: float()
            }
          ],
          expected_match_id: binary() | nil
        }

  @doc """
  Returns all cases in the synthetic evaluation set.
  """
  @spec cases() :: [eval_case()]
  def cases do
    clear_match_cases() ++ near_miss_cases() ++ multi_trigger_cases() ++ no_match_cases()
  end

  @doc """
  Cases where the patient burst clearly matches the trigger condition (p >= 0.7).
  """
  def clear_match_cases do
    [
      %{
        id: :dispute_mother,
        category: :clear_match,
        description: "Paciente relata discusión reciente con su madre",
        patient_message:
          "Ayer tuve una discusión muy fuerte con mi mamá, me gritó y quedamos sin hablarnos.",
        candidates: [
          %{
            id: "trig-mother-01",
            condition: "Habla de una discusión reciente o conflicto con su madre",
            approved_text: "¿Te gustaría revisar cómo manejar esa conversación con tu mamá?",
            mock_noul: 0.94
          }
        ],
        expected_match_id: "trig-mother-01"
      },
      %{
        id: :insomnia_crisis,
        category: :clear_match,
        description: "Paciente reporta insomnio persistente",
        patient_message:
          "Llevo tres noches seguidas sin poder dormir nada, me desvelo a las 3 am y no puedo volver a dormir.",
        candidates: [
          %{
            id: "trig-insomnia-01",
            condition:
              "Menciona insomnio, dificultad persistente para conciliar el sueño o desvelos",
            approved_text: "Recuerda la técnica de higiene del sueño que practicamos en sesión.",
            mock_noul: 0.91
          }
        ],
        expected_match_id: "trig-insomnia-01"
      },
      %{
        id: :quit_therapy,
        category: :clear_match,
        description: "Paciente expresa deseos de abandonar el tratamiento",
        patient_message:
          "Siento que no avanzo nada y la verdad estoy pensando seriamente en dejar la terapia.",
        candidates: [
          %{
            id: "trig-quit-01",
            condition:
              "Expresa dudas sobre continuar el proceso o deseos de abandonar la terapia",
            approved_text:
              "Es normal sentir frustración en el proceso; lo podemos conversar en la próxima sesión.",
            mock_noul: 0.88
          }
        ],
        expected_match_id: "trig-quit-01"
      }
    ]
  end

  @doc """
  Cases where the patient message is related or adjacent to the trigger condition,
  but does NOT satisfy it (probability strictly below threshold 0.7).
  """
  def near_miss_cases do
    [
      %{
        id: :near_mother_casual,
        category: :near_miss,
        description: "Menciona a la madre de forma casual sin conflicto ni discusión",
        patient_message:
          "Hablé con mi mamá por teléfono para coordinar el almuerzo del domingo, todo bien.",
        candidates: [
          %{
            id: "trig-mother-02",
            condition: "Habla de una discusión reciente o conflicto con su madre",
            approved_text: "¿Te gustaría revisar cómo manejar esa conversación con tu mamá?",
            mock_noul: 0.32
          }
        ],
        expected_match_id: nil
      },
      %{
        id: :near_sleep_nap,
        category: :near_miss,
        description: "Menciona siesta o cansancio común sin insomnio clínico",
        patient_message:
          "Hoy me dio un poco de sueño después de almorzar, así que descansé media hora.",
        candidates: [
          %{
            id: "trig-insomnia-02",
            condition:
              "Menciona insomnio, dificultad persistente para conciliar el sueño o desvelos",
            approved_text: "Recuerda la técnica de higiene del sueño que practicamos en sesión.",
            mock_noul: 0.25
          }
        ],
        expected_match_id: nil
      },
      %{
        id: :near_miss_boundary_065,
        category: :near_miss,
        description: "Caso limítrofe de ansiedad que queda justo bajo el umbral 0.7 (p = 0.65)",
        patient_message:
          "Estaba algo inquieto antes de la presentación de hoy en la oficina, pero salió bien.",
        candidates: [
          %{
            id: "trig-panic-01",
            condition:
              "Describe ataques de pánico agudos, crisis de angustia o taquicardia severa",
            approved_text:
              "¿Quieres que hagamos un breve ejercicio de respiración diafragmática?",
            mock_noul: 0.65
          }
        ],
        expected_match_id: nil
      }
    ]
  end

  @doc """
  Cases with multiple candidate triggers, where more than one may pass the threshold,
  and the highest probability above 0.7 must win.
  """
  def multi_trigger_cases do
    [
      %{
        id: :multi_work_and_mother,
        category: :multi_trigger,
        description:
          "Mensaje menciona conflicto laboral y discusión con madre; madre tiene mayor probabilidad",
        patient_message:
          "Hoy en la oficina mi jefe me criticó por un informe, pero lo que de verdad me quebró fue que al llegar a la casa me puse a pelear a gritos con mi mamá.",
        candidates: [
          %{
            id: "trig-work-conflict",
            condition:
              "Menciona problemas, tensión o conflicto laboral con jefatura o compañeros",
            approved_text: "¿Cómo te sentiste ante ese momento de tensión en el trabajo?",
            mock_noul: 0.79
          },
          %{
            id: "trig-mother-clash",
            condition: "Habla de una discusión reciente o conflicto con su madre",
            approved_text: "¿Te gustaría revisar cómo manejar esa conversación con tu mamá?",
            mock_noul: 0.95
          },
          %{
            id: "trig-substance-use",
            condition: "Menciona consumo de alcohol o sustancias tras una situación difícil",
            approved_text: "Recuerda las alternativas de autorregulación que acordamos.",
            mock_noul: 0.15
          }
        ],
        expected_match_id: "trig-mother-clash"
      },
      %{
        id: :multi_work_wins,
        category: :multi_trigger,
        description:
          "Mensaje donde el conflicto laboral supera al cansancio físico (0.89 vs 0.74)",
        patient_message:
          "Tuve una reunión terrible donde el jefe me descalificó delante de todos los compañeros. Terminé con dolor de cabeza.",
        candidates: [
          %{
            id: "trig-headache",
            condition: "Menciona dolor de cabeza o síntomas psicosomáticos de malestar",
            approved_text: "Nota si tu cuerpo te está avisando que necesitas una pausa.",
            mock_noul: 0.74
          },
          %{
            id: "trig-work-humiliation",
            condition:
              "Menciona problemas, tensión o conflicto laboral con jefatura o compañeros",
            approved_text: "¿Cómo te sentiste ante ese momento de tensión en el trabajo?",
            mock_noul: 0.89
          }
        ],
        expected_match_id: "trig-work-humiliation"
      }
    ]
  end

  @doc """
  Cases where the patient message is completely unrelated to candidate triggers.
  """
  def no_match_cases do
    [
      %{
        id: :unrelated_groceries,
        category: :no_match,
        description: "Mensaje sobre compras cotidianas sin relevancia clínica",
        patient_message: "Hoy fui al supermercado y compré verduras, fruta y pan para la semana.",
        candidates: [
          %{
            id: "trig-mother-03",
            condition: "Habla de una discusión reciente o conflicto con su madre",
            approved_text: "¿Te gustaría revisar cómo manejar esa conversación con tu mamá?",
            mock_noul: 0.05
          },
          %{
            id: "trig-insomnia-03",
            condition:
              "Menciona insomnio, dificultad persistente para conciliar el sueño o desvelos",
            approved_text: "Recuerda la técnica de higiene del sueño que practicamos en sesión.",
            mock_noul: 0.02
          }
        ],
        expected_match_id: nil
      }
    ]
  end
end
