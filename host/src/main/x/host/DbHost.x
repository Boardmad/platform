import ecstasy.io.Log;

import ecstasy.mgmt.ModuleRepository;

import ecstasy.reflect.AnnotationTemplate;
import ecstasy.reflect.ClassTemplate;
import ecstasy.reflect.ClassTemplate.Composition;
import ecstasy.reflect.ClassTemplate.Contribution;
import ecstasy.reflect.MethodTemplate;
import ecstasy.reflect.ModuleTemplate;
import ecstasy.reflect.MultiMethodTemplate;
import ecstasy.reflect.ParameterTemplate;
import ecstasy.reflect.PropertyTemplate;
import ecstasy.reflect.TypeParameter;
import ecstasy.reflect.TypeTemplate;

import oodb.DBObject.DBCategory;
import oodb.RootSchema;


/**
 * An abstract host for a DB module.
 */
@Abstract
class DbHost(String moduleName, Directory homeDir)
        extends common.AppHost(moduleName, homeDir)
    {
    @Override
    void close(Exception? e)
        {
        closeDatabase();
        }


    // ---- run-time support -----------------------------------------------------------------------

    /**
     * The actual [RootSchema] type associated with the DB module represented by this DbHost.
     */
    @RO Type<RootSchema> schemaType;

    /**
     * Check an existence of the DB (e.g. on disk); create or recover if necessary.
     *
     * @return a connection factory
     */
    function oodb.Connection(oodb.DBUser)
        ensureDatabase(Map<String, String>? configOverrides = Null);

    /**
     * Life cycle: close the database.
     */
    void closeDatabase();


    // ---- load-time support ----------------------------------------------------------------------

    /**
     * The host name (json, imdb, etc).
     */
    @Abstract
    @RO String hostName;

    @Abstract
    @RO String moduleSourceTemplate;

    @Abstract
    @RO String propertyGetterTemplate;

    @Abstract
    @RO String propertyInfoTemplate;

    @Abstract
    @RO String customInstantiationTemplate;

    @Abstract
    @RO String customDeclarationTemplate;

    @Abstract
    @RO String customMethodTemplate;

    /**
     * Generate (if necessary) all the necessary classes to use a DB modules.
     *
     * @param repository  the repository to load necessary modules from
     * @param buildDir    the directory to place all generated artifacts to
     * @param errors      the error log
     *
     * @return True iff the module template was successfully created
     * @return the generated module (optional)
     */
    conditional ModuleTemplate ensureDBModule(
            ModuleRepository repository, Directory buildDir, Log errors)
        {
        ModuleTemplate dbModule   = repository.getResolvedModule(moduleName);
        String         hostedName = $"{moduleName}_{hostName}";

        if (ModuleTemplate hostModule := repository.getModule(hostedName))
            {
            // try to see if the host module is newer than the original module;
            // if anything goes wrong - follow a regular path
            try
                {
                DateTime? dbStamp    = dbModule.parent.created;
                DateTime? hostStamp  = hostModule.parent.created;
                if (dbStamp != Null && hostStamp != Null && hostStamp > dbStamp)
                    {
                    errors.add($"Info: Host module '{hostedName}' for '{moduleName}' is up to date");
                    return True, hostModule;
                    }
                }
            catch (Exception ignore) {}
            }

        String appName = moduleName; // TODO GG: allow fully qualified name

        ClassTemplate appSchemaTemplate;
        if (!(appSchemaTemplate := findSchema(dbModule)))
            {
            errors.add($"Error: Schema is not found in module '{moduleName}'");
            return False;
            }

        File sourceFile = buildDir.fileFor($"{appName}_{hostName}.x");

        if (createModule(sourceFile, appName, dbModule, appSchemaTemplate, errors) &&
            compileModule(repository, sourceFile, buildDir, errors))
            {
            errors.add($"Info: Created a host module '{hostedName}' for '{moduleName}'");
            return repository.getModule(hostedName);
            }
        return False;
        }

    /**
     * Create module source file.
     */
    Boolean createModule(File sourceFile, String appName,
                         ModuleTemplate moduleTemplate, ClassTemplate appSchemaTemplate, Log errors)
        {
        String appSchema = appSchemaTemplate.name;

        Tuple<PropertyTemplate, DBCategory>[] dbProps;
        if (!(dbProps := collectDBProps(appSchemaTemplate, errors)))
            {
            return False;
            }

        String childrenIds          = "";
        String propertyInfos        = "";
        String propertyTypes        = "";
        String propertyGetters      = "";
        String customInstantiations = "";
        String customDeclarations   = "";

        Int pid = 0;
        for (Tuple<PropertyTemplate, DBCategory> propInfo : dbProps)
            {
            PropertyTemplate property = propInfo[0];
            DBCategory       category = propInfo[1];

            TypeTemplate typeTemplate = property.type;

            // already checked at collectDBProps()
            assert Composition classTemplate := typeTemplate.fromClass(),
                   classTemplate.is(ClassTemplate);

            String propertyName  = property.name;
            String propertyType  = displayName(typeTemplate, appName);
            String propertyId    = (++pid).toString();
            String transactional = "True";
            String options       = "";

            String propertyTypeName = classTemplate.name.replace(".", "_");
            String propertyStoreType;
            String propertyBaseType;
            String propertyTypeParams;

            childrenIds += $"{propertyId},";
            switch (category)
                {
                case DBMap:
                    TypeTemplate keyType;
                    TypeTemplate valueType;
                    if (keyType   := resolveFormalType(typeTemplate, "Key",   propertyName, errors),
                        valueType := resolveFormalType(typeTemplate, "Value", propertyName, errors)) {}
                    else
                        {
                        return False;
                        }

                    String keyTypeName   = displayName(keyType, appName);
                    String valueTypeName = displayName(valueType, appName);

                    propertyStoreType  = $"{hostName}_.storage.MapStore<{keyTypeName}, {valueTypeName}>";
                    propertyBaseType   = $"DBMapImpl<{keyTypeName}, {valueTypeName}>";
                    propertyTypeParams = $"\"Key\"={keyTypeName}, \"Value\"={valueTypeName}";
                    break;

                case DBCounter:
                    propertyStoreType  = "{hostName}_.storage.CounterStore";
                    propertyBaseType   = "DBCounterImpl";
                    propertyTypeParams = "";

                    if (AnnotationTemplate annotation := property.findAnnotation("oodb.NoTx"))
                        {
                        transactional = "False";
                        }
                    break;

                case DBValue:
                    TypeTemplate valueType;
                    if (!(valueType := resolveFormalType(typeTemplate, "Value", propertyName, errors)))
                        {
                        return False;
                        }

                    String valueTypeName = displayName(valueType, appName);

                    propertyStoreType  = $"{hostName}_.storage.ValueStore<{valueTypeName}>";
                    propertyBaseType   = $"DBValueImpl<{valueTypeName}>";
                    propertyTypeParams = $"\"Value\"={valueTypeName}";

                    String initialValue = "Null";
                    if (AnnotationTemplate annotation := property.findAnnotation("oodb.Initial"))
                        {
                        initialValue = displayValue(annotation.arguments[0].value);
                        }

                    if (initialValue == "Null")
                        {
                        if (Const initial := property.hasInitialValue())
                            {
                            initialValue = displayValue(initial);
                            }
                        else
                            {
                            errors.add($"Error: Property \"{propertyName}\" must specify an initial value");
                            return False;
                            }
                        }
                    options = $"\"initial\"={initialValue}";
                    break;

                case DBLog:
                    TypeTemplate elementType;
                    if (!(elementType := resolveFormalType(typeTemplate, "Element", propertyName, errors)))
                        {
                        return False;
                        }

                    String elementTypeName = displayName(elementType, appName);

                    propertyStoreType  = $"{hostName}_.storage.LogStore<{elementTypeName}>";
                    propertyBaseType   = $"DBLogImpl<{elementTypeName}>";
                    propertyTypeParams = $"\"Element\"={elementTypeName}";

                    if (AnnotationTemplate annotation := property.findAnnotation("oodb.NoTx"))
                        {
                        transactional = "False";
                        }
                    if (AnnotationTemplate annotation := property.findAnnotation("oodb.AutoExpire"))
                        {
                        Duration expiry = annotation.arguments[0].value.as(Duration);
                        options += $"\"expiry\"=Duration:{expiry.seconds}s";
                        }

                    if (AnnotationTemplate annotation := property.findAnnotation("oodb.AutoTruncate"))
                        {
                        Int truncateSize = annotation.arguments[0].value.as(Int);
                        if (options.size > 0)
                            {
                            options += ", ";
                            }
                        options += $"\"truncate\"=Int:{truncateSize}";
                        }

                    break;

                case DBProcessor:
                    TypeTemplate messageType;
                    if (!(messageType := resolveFormalType(typeTemplate, "Message", propertyName, errors)))
                        {
                        return False;
                        }

                    String messageTypeName = displayName(messageType, appName);

                    propertyStoreType  = $"{hostName}_.storage.ProcessorStore<{messageTypeName}>";
                    propertyBaseType   = $"DBProcessorImpl<{messageTypeName}>";
                    propertyTypeParams = $"\"Message\"={messageTypeName}";
                    break;

                default:
                    TODO
                }

            propertyInfos += propertyInfoTemplate
                                .replace("%propertyName%"      , propertyName)
                                .replace("%propertyCategory%"  , category.name)
                                .replace("%propertyId%"        , propertyId)
                                .replace("%propertyParentId%"  , "0") // TODO
                                .replace("%propertyType%"      , propertyType)
                                .replace("%propertyTypeParams%", propertyTypeParams)
                                .replace("%transactional%"     , transactional)
                                .replace("%options%"           , options)
                                ;

            propertyGetters += propertyGetterTemplate
                                .replace("%appName%"     , appName)
                                .replace("%propertyName%", propertyName)
                                .replace("%propertyId%"  , propertyId)
                                .replace("%propertyType%", propertyType)
                                ;

            if (classTemplate.containingModule != moduleTemplate)
                {
                continue;
                }

            String customMethods = createMethods(appName, classTemplate);

            customInstantiations += customInstantiationTemplate
                                    .replace("%appName%"          , appName)
                                    .replace("%propertyName%"     , propertyName)
                                    .replace("%propertyId%"       , propertyId)
                                    .replace("%propertyType%"     , propertyType)
                                    .replace("%propertyTypeName%" , propertyTypeName)
                                    .replace("%propertyStoreType%", propertyStoreType)
                                    ;

            customDeclarations += customDeclarationTemplate
                                    .replace("%propertyType%"     , propertyType)
                                    .replace("%propertyTypeName%" , propertyTypeName)
                                    .replace("%propertyStoreType%", propertyStoreType)
                                    .replace("%propertyBaseType%" , propertyBaseType)
                                    .replace("%CustomMethods%"    , customMethods)
                                    ;
            }

        String schemaMethods = createMethods(appName, appSchemaTemplate);

        String moduleSource = moduleSourceTemplate
                                .replace("%appName%"             , appName)
                                .replace("%appSchema%"           , appSchema)
                                .replace("%ChildrenIds%"         , childrenIds)
                                .replace("%PropertyInfos%"       , propertyInfos)
                                .replace("%PropertyTypes%"       , propertyTypes)
                                .replace("%PropertyGetters%"     , propertyGetters)
                                .replace("%SchemaMethods%"       , schemaMethods)
                                .replace("%CustomInstantiations%", customInstantiations)
                                .replace("%CustomDeclarations%"  , customDeclarations)
                                ;

        sourceFile.create();
        writeUtf(sourceFile, moduleSource);
        return True;
        }

    String createMethods(String appName, ClassTemplate classTemplate)
        {
        String customMethods = "";

        for (MultiMethodTemplate multimethod : classTemplate.multimethods)
            {
            String methodName = multimethod.name;
            for (MethodTemplate method : multimethod.children())
                {
                if (!method.isConstructor && !method.isStatic && method.access == Public)
                    {
                    ParameterTemplate[] params  = method.parameters;
                    ParameterTemplate[] returns = method.returns;

                    String retType = switch (returns.size)
                            {
                            case 0 : "void";
                            case 1 : displayName(returns[0].type, appName);
                            default: $"({{for (val r : returns) {$.addAll(displayName(r.type, appName)); $.add(',');} }})";

// TODO CP: the equivalent multi-line doesn't parse
//                                default: $|({{for (val r : returns)
//                                          |    {
//                                          |    $.addAll(displayName(r.type, appName));
//                                          |    $.add(',');
//                                          |    }
//                                          |}})
//                                          ;
                            };

                    String argDecl     = "";
                    String args        = "";
                    String argTypes    = "";
                    String tupleValues = "";
                    switch (params.size)
                        {
                        case 0:
                            break;

                        case 1:
                            args        = params[0].name? : assert;
                            argTypes    = displayName(params[0].type, appName);
                            argDecl     = $"{argTypes} {args}";
                            tupleValues = "args[0]";
                            break;

                        default:
                            Loop:
                            for (ParameterTemplate param : params)
                                {
                                String name = param.name? : assert;
                                String type = displayName(param.type, appName);

                                if (!Loop.first)
                                    {
                                    argDecl     += ", ";
                                    args        += ", ";
                                    argTypes    += ", ";
                                    tupleValues += ", ";
                                    }
                                argDecl     += $"{type} {name}";
                                args        += name;
                                argTypes    += type;
                                tupleValues += $"args[{Loop.count}]";
                                }
                            break;
                        }

                    customMethods += customMethodTemplate
                                        .replace("%appName%", appName)
                                        .replace("%name%"   , methodName)
                                        .replace("%retType%", retType)
                                        .replace("%argDecl%", argDecl)
                                        .replace("%args%"   , args)
                                        ;
                    }
                }
            }

        return customMethods;
        }

    // ----- common helper methods -----------------------------------------------------------------

    /**
     * Find a DB schema.
     */
    conditional ClassTemplate findSchema(ModuleTemplate dbModule)
        {
        Class         schemaClass    = oodb.RootSchema;
        ClassTemplate schemaTemplate = schemaClass.baseTemplate;

        for (ClassTemplate classTemplate : dbModule.classes)
            {
            if (classTemplate.format == Interface)
                {
                for (Contribution contrib : classTemplate.contribs)
                    {
                    if (contrib.action == Implements)
                        {
                        ClassTemplate template = contrib.ingredient.as(ClassTemplate);
                        if (template == schemaTemplate)
                            {
                            return True, classTemplate;
                            }
                        }
                    }
                }
            }
        return False;
        }

    /**
     * Collect all DB properties.
     */
    conditional Tuple<PropertyTemplate, DBCategory>[]
            collectDBProps(ClassTemplate appSchemaTemplate, Log errors)
        {
        Tuple<PropertyTemplate, DBCategory>[] properties = new Array();

        NextProperty:
        for (PropertyTemplate prop : appSchemaTemplate.properties)
            {
            TypeTemplate typeTemplate = prop.type;

            if (Composition classTemplate := typeTemplate.fromClass(),
                            classTemplate.is(ClassTemplate))
                {
                for ((DBCategory category, TypeTemplate dbType) : DB_TEMPLATES)
                    {
                    if (typeTemplate.isA(dbType))
                        {
                        properties += Tuple:(prop, category);
                        continue NextProperty;
                        }
                    }
                }
            errors.add($"Error: Unsupported property type: \"{prop.type} {prop.name}\"");
            return False;
            }

        // TODO recurse to super template
        return True, properties;
        }

    /**
     * Obtain the formal type for the specified name; log an error if the type cannot be resolved.
     */
    conditional TypeTemplate resolveFormalType(TypeTemplate typeTemplate, String formalName,
                                               String propertyName, Log errors)
        {
        if (TypeTemplate typeFormal := typeTemplate.resolveFormalType(formalName))
            {
            return True, typeFormal;
            }
        errors.add($"Error: Property {propertyName.quoted()} must specify {formalName.quoted()} type");
        return False;
        }

    /**
     * Obtain a display name for the specified type for the specified application.
     */
    String displayName(TypeTemplate type, String appName)
        {
        assert Composition composition := type.fromClass();

        String name = displayName(composition, appName);

        if (TypeTemplate[] typeParams := type.parameterized())
            {
            StringBuffer buf = new StringBuffer(name.size * typeParams.size);
            buf.append(name)
               .add('<');

            loop:
            for (TypeTemplate typeParam : typeParams)
                {
                if (!loop.first)
                    {
                    buf.append(", ");
                    }
                buf.append(displayName(typeParam, appName));
                }
            buf.add('>');
            name = buf.toString();
            }
        return name;
        }

    /**
     * Obtain a display name for the specified composition for the specified application.
     */
    String displayName(Composition composition, String appName)
        {
        if (composition.is(ClassTemplate))
            {
            return composition.implicitName ?: (appName + "_." + composition.displayName);
            }
        TODO AnnotatingComposition
        }

    /**
     * Obtain a display values for the specified constant.
     */
    String displayValue(Const value)
        {
        Type typeActual = &value.actualType;
        if (typeActual.is(Type<String>))
            {
            return value.as(String).quoted();
            }
        if (typeActual.is(Type<Char>))
            {
            return $"'{value.as(Char).toString()}'";
            }

        return value.toString();
        }

    /**
     * Compile the specified source file.
     */
    Boolean compileModule(ModuleRepository repository, File sourceFile, Directory buildDir, Log errors)
        {
        @Inject ecstasy.lang.src.Compiler compiler;

        compiler.setLibraryRepository(repository);
        compiler.setResultLocation(buildDir);

        (Boolean success, String[] compilationErrors) = compiler.compile([sourceFile]);

        if (compilationErrors.size > 0)
            {
            errors.addAll(compilationErrors);
            }
        return success;
        }

    /**
     * The code below should be replaced with
     *      file.contents = contents.utfBytes();
     */
    void writeUtf(File file, String contents)
        {
        import ecstasy.io.ByteArrayOutputStream as Stream;
        import ecstasy.io.UTF8Writer;
        import ecstasy.io.Writer;

        Stream out    = new Stream(contents.size);
        Writer writer = new UTF8Writer(out);
        writer.addAll(contents);

        file.contents = out.bytes.freeze(True);
        }


    // ----- constants -----------------------------------------------------------------------------

    static Map<DBCategory, TypeTemplate> DB_TEMPLATES = Map:
            [
            DBSchema    = oodb.DBSchema   .baseTemplate.type,
            DBCounter   = oodb.DBCounter  .baseTemplate.type,
            DBValue     = oodb.DBValue    .baseTemplate.type,
            DBMap       = oodb.DBMap      .baseTemplate.type,
            DBList      = oodb.DBList     .baseTemplate.type,
            DBQueue     = oodb.DBQueue    .baseTemplate.type,
            DBProcessor = oodb.DBProcessor.baseTemplate.type,
            DBLog       = oodb.DBLog      .baseTemplate.type,
            ];
    }