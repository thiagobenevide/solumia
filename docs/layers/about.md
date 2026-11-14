[README](../../README.md) · [Local models](local-models.md) · [Cloud LLMs](cloud-llms.md) · [Backend](backend.md) · [Frontend](frontend.md) · [Security](security.md) · [Network](network.md) · [Data](data.md) · [DevOps](devops.md) · [Modules](modules.md)

# How this documentation is organized

The structure follows what software engineering research reports about useful documentation: **a short entry
point, separate views per concern, and recorded decisions.**

## Principles and their sources

| Principle applied here | Source |
|---|---|
| **README as the entry point**: what it is, why, how to use it, where to go next | Prana et al. (2019) classified GitHub README content and found *what* and *how* sections to be the most common and useful, while *why*, *who* and *references* are often missing |
| **One page per layer** (architectural views) | Kruchten (1995), 4+1 view model, and Clements et al. (2010), *Views and Beyond*: each audience reads the view that matches its concern; no single view serves everyone |
| **Diagrams by level of detail** (system, containers, components) | C4 model (Brown): the overview lives in the README, details in each layer page |
| **Separate kinds of text** (how-to, reference, explanation) | Diátaxis (Procida): commands are step-by-step blocks, tables are reference, rationale is explanation |
| **Decisions recorded with their rationale** | Nygard (2011), Architecture Decision Records; Parnas and Clements (1986): documenting the design "as if" it had been rational helps future maintainers |
| **Document what maintenance actually needs** | de Souza, Anquetil and de Oliveira (2005), a Brazilian study on documentation essential to maintenance: data models, architectural overviews and source comments outweigh lengthy documents |
| **Short and current beats complete and stale** | Forward and Lethbridge (2002) and Aghajani et al. (2019, 2020): incompleteness and obsolescence are the most reported documentation issues, so every page points to the source file it describes |
| **Lower the barrier for newcomers** | Steinmacher et al. (2015) and Steinmacher, Treude and Gerosa (2019), Brazilian-led research: lack of orientation is one of the largest barriers for newcomers, hence "Getting started" and "Adding a module" |
| **Document models and datasets** | Mitchell et al. (2019), *Model Cards*, and Gebru et al. (2021), *Datasheets for Datasets*, applied to LoRA adapters and the pipeline dataset |
| **Categorized threats** | STRIDE (Kohnfelder & Garg, 1999) and OWASP ASVS in the security layer |

## Navigation

GitHub does not support tabs inside a README. It renders standard community files as **repository tabs**:
`README`, `LICENSE`, `SECURITY.md` (the *Security* tab) and, when present, `CONTRIBUTING.md` and
`CODE_OF_CONDUCT.md`. Layer navigation is therefore a **link bar at the top of every page**, and the security
policy lives in `SECURITY.md`. Diagrams use **Mermaid**, which GitHub renders natively.

## Maintenance

- Changed a route, worker task or port? Update the layer table in the same commit.
- New architecture decision: add a row to [ARCHITECTURE.md](../ARCHITECTURE.md) (context, decision, rationale).
- New module: add a row to [Modules](modules.md) and write `modulos/<m>/README.md`.

## References

Aghajani, E., Nagy, C., Vega-Márquez, O. L., Linares-Vásquez, M., Moreno, L., Bavota, G., & Lanza, M. (2019).
Software documentation issues unveiled. In *Proceedings of the 41st International Conference on Software
Engineering (ICSE)* (pp. 1199–1210). IEEE.

Aghajani, E., Nagy, C., Linares-Vásquez, M., Moreno, L., Bavota, G., Lanza, M., & Shepherd, D. C. (2020).
Software documentation: The practitioners' perspective. In *Proceedings of the 42nd International Conference
on Software Engineering (ICSE)*. ACM.

Brown, S. *The C4 model for visualising software architecture*. https://c4model.com

Clements, P., Bachmann, F., Bass, L., Garlan, D., Ivers, J., Little, R., Merson, P., Nord, R., & Stafford, J.
(2010). *Documenting software architectures: Views and beyond* (2nd ed.). Addison-Wesley.

de Souza, S. C. B., Anquetil, N., & de Oliveira, K. M. (2005). A study of the documentation essential to
software maintenance. In *Proceedings of the 23rd Annual International Conference on Design of Communication
(SIGDOC)* (pp. 68–75). ACM.

Forward, A., & Lethbridge, T. C. (2002). The relevance of software documentation, tools and technologies: A
survey. In *Proceedings of the 2002 ACM Symposium on Document Engineering (DocEng)* (pp. 26–33). ACM.

Gebru, T., Morgenstern, J., Vecchione, B., Vaughan, J. W., Wallach, H., Daumé III, H., & Crawford, K. (2021).
Datasheets for datasets. *Communications of the ACM, 64*(12), 86–92.

Kohnfelder, L., & Garg, P. (1999). *The threats to our products*. Microsoft.

Kruchten, P. B. (1995). The 4+1 view model of architecture. *IEEE Software, 12*(6), 42–50.

Mitchell, M., Wu, S., Zaldivar, A., Barnes, P., Vasserman, L., Hutchinson, B., Spitzer, E., Raji, I. D., &
Gebru, T. (2019). Model cards for model reporting. In *Proceedings of the Conference on Fairness,
Accountability, and Transparency (FAT\*)* (pp. 220–229). ACM.

Nygard, M. (2011). *Documenting architecture decisions*.
https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions

OWASP Foundation. *Application Security Verification Standard (ASVS)*.
https://owasp.org/www-project-application-security-verification-standard/

Parnas, D. L., & Clements, P. C. (1986). A rational design process: How and why to fake it. *IEEE
Transactions on Software Engineering, SE-12*(2), 251–257.

Prana, G. A. A., Treude, C., Thung, F., Atapattu, T., & Lo, D. (2019). Categorizing the content of GitHub
README files. *Empirical Software Engineering, 24*(3), 1296–1327.

Procida, D. *Diátaxis: A systematic approach to technical documentation authoring*. https://diataxis.fr

Steinmacher, I., Silva, M. A. G., Gerosa, M. A., & Redmiles, D. F. (2015). A systematic literature review on
the barriers faced by newcomers to open source software projects. *Information and Software Technology, 59*,
67–85.

Steinmacher, I., Treude, C., & Gerosa, M. A. (2019). Let me in: Guidelines for the successful onboarding of
newcomers to open source projects. *IEEE Software, 36*(4), 41–49.
